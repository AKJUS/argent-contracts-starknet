use argent::signer::signer_signature::SignerStorageValue;

trait IUpgradeMigrationInternal<TContractState> {
    fn migrate_from_before_0_4_0(ref self: TContractState);
    fn migrate_from_0_4_0(ref self: TContractState);
}

trait IUpgradeMigrationCallback<TContractState> {
    fn finalize_migration(ref self: TContractState);
    fn migrate_owner(ref self: TContractState, signer_storage_value: SignerStorageValue);
}

/// Trait for recovering the `_signer` storage slot
///
/// This trait defines a mechanism to correct potential issues with the `_signer` storage slot following a contract
/// upgrade that wasn't done correctly.
/// This can happen if the contract was upgraded from 0.2.3 with an empty calldata array.
///  The `recover_signer` function ensures that if the `_signer` slot was not properly updated during an upgrade, it can
///  be safely recovered to that signer, preventing the contract from staying in an unusable state.
#[starknet::interface]
trait IRecoverSigner<TContractState> {
    fn recover_signer(ref self: TContractState);
}

#[derive(Drop, Copy, Serde, Default, starknet::Store)]
struct LegacyEscape {
    // timestamp for activation of escape mode, 0 otherwise
    ready_at: u64,
    // None (0x0), Guardian (0x1), Owner (0x2)
    escape_type: felt252,
    // new owner or new guardian address
    new_signer: felt252,
}

#[starknet::component]
mod upgrade_migration_component {
    use argent::account::interface::IEmitArgentAccountEvent;
    use argent::multiowner_account::account_interface::IArgentMultiOwnerAccount;
    use argent::multiowner_account::argent_account::ArgentAccount::Event as ArgentAccountEvent;
    use argent::multiowner_account::events::{EscapeCanceled, SignerLinked};
    use argent::multiowner_account::recovery::Escape;
    use argent::signer::signer_signature::{
        SignerStorageValue, SignerType, Signer, starknet_signer_from_pubkey, SignerTrait
    };
    use argent::upgrade::interface::{IUpgradableCallback, IUpgradeable, IUpgradableCallbackDispatcherTrait};
    use starknet::{
        syscalls::replace_class_syscall, SyscallResultTrait, get_block_timestamp, storage::Map,
        storage_access::{storage_read_syscall, storage_address_from_base_and_offset, storage_base_address_from_felt252,}
    };
    use super::{IRecoverSigner, IUpgradeMigrationInternal, IUpgradeMigrationCallback, LegacyEscape};

    const LEGACY_ESCAPE_SECURITY_PERIOD: u64 = 7 * 24 * 60 * 60; // 7 days

    #[storage]
    struct Storage {
        // storage layout used to be different before 0.4.0
        _escape: LegacyEscape,
        // Legacy storage
        _signer: felt252,
        _implementation: felt252,
        guardian_escape_attempts: felt252,
        owner_escape_attempts: felt252,
        // 0.4.0
        _signer_non_stark: Map<felt252, felt252>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}


    #[embeddable_as(RecoverSignerImpl)]
    impl RecoverSigner<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        +IUpgradeMigrationCallback<TContractState>,
        +IArgentMultiOwnerAccount<TContractState>,
        +IEmitArgentAccountEvent<TContractState>,
    > of IRecoverSigner<ComponentState<TContractState>> {
        fn recover_signer(ref self: ComponentState<TContractState>) {
            assert(self._signer.read() != 0, 'argent/no-signer-to-recover');
            assert(self._implementation.read() != 0, 'argent/wrong-implementation');
            self.migrate_from_before_0_4_0();
            // Ensuring the recovery was successful
            assert(self._signer.read() == 0, 'argent/signer-not-removed');
            assert(self._implementation.read() == 0, 'argent/impl-not-removed');
        }
    }

    impl UpgradeMigrationInternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        +IUpgradeMigrationCallback<TContractState>,
        +IArgentMultiOwnerAccount<TContractState>,
        +IEmitArgentAccountEvent<TContractState>,
    > of IUpgradeMigrationInternal<ComponentState<TContractState>> {
        fn migrate_from_before_0_4_0(ref self: ComponentState<TContractState>) {
            let legacy_escape = self._escape.read();
            if legacy_escape.ready_at != 0 && get_block_timestamp() < legacy_escape.ready_at
                + LEGACY_ESCAPE_SECURITY_PERIOD {
                // Active escape. Automatically cancelling the escape with the upgrade
                self.emit_event(ArgentAccountEvent::EscapeCanceled(EscapeCanceled {}));
            }
            // Clear the escape
            self._escape.write(Default::default());

            // Cleaning attempts storage as the escape was cleared
            self.owner_escape_attempts.write(0);
            self.guardian_escape_attempts.write(0);

            // Check basic invariants and emit missing events
            let owner_key = self._signer.read();
            assert(owner_key != 0, 'argent/null-owner');

            let argent_account = self.get_contract();
            let guardian_key = argent_account.get_guardian();
            let guardian_backup_key = argent_account.get_guardian_backup();
            if guardian_key == 0 {
                assert(guardian_backup_key == 0, 'argent/backup-should-be-null');
            } else {
                let guardian = starknet_signer_from_pubkey(guardian_key);
                let guardian_linked = SignerLinked { signer_guid: guardian.into_guid(), signer: guardian };
                self.emit_event(ArgentAccountEvent::SignerLinked(guardian_linked));
                if guardian_backup_key != 0 {
                    let guardian_backup = starknet_signer_from_pubkey(guardian_backup_key);
                    let guardian_backup_linked = SignerLinked {
                        signer_guid: guardian_backup.into_guid(), signer: guardian_backup
                    };
                    self.emit_event(ArgentAccountEvent::SignerLinked(guardian_backup_linked));
                }
            }

            let owner = starknet_signer_from_pubkey(owner_key);
            let owner_linked = SignerLinked { signer_guid: owner.into_guid(), signer: owner };
            self.emit_event(ArgentAccountEvent::SignerLinked(owner_linked));

            let implementation = self._implementation.read();

            if implementation != Zeroable::zero() {
                replace_class_syscall(implementation.try_into().unwrap()).expect('argent/invalid-after-upgrade');
                self._implementation.write(Zeroable::zero());
            }

            self.migrate_from_0_4_0();
        }

        fn migrate_from_0_4_0(ref self: ComponentState<TContractState>) {
            // Reset proxy slot, changing the ClassHash is done in the upgrade callback
            self._implementation.write(0);
            // During an upgrade we changed the layout from being 3 fields to 3 fields packed onto 2 fields.
            // We need to restore that third field that could have been left behind.
            self._escape.new_signer.write(0);

            let starknet_owner_pubkey = self._signer.read();
            if (starknet_owner_pubkey != 0) {
                let stark_signer = starknet_signer_from_pubkey(starknet_owner_pubkey).storage_value();
                self.migrate_owner(stark_signer);
                self._signer.write(0);
            } else {
                for signer_type in array![
                    SignerType::Webauthn, SignerType::Secp256k1, SignerType::Secp256r1, SignerType::Eip191
                ] {
                    let stored_value = self._signer_non_stark.read(signer_type.into());
                    if (stored_value != 0) {
                        let signer_storage_value = SignerStorageValue { signer_type, stored_value };
                        self.migrate_owner(signer_storage_value);
                        self._signer_non_stark.write(signer_type.into(), 0);
                        break;
                    }
                };
            }

            // Health check
            self.finalize_migration();
        }
    }

    #[generate_trait]
    impl Private<
        TContractState,
        +HasComponent<TContractState>,
        +IUpgradeMigrationCallback<TContractState>,
        +Drop<TContractState>,
        +IEmitArgentAccountEvent<TContractState>,
    > of PrivateTrait<TContractState> {
        fn emit_event(ref self: ComponentState<TContractState>, event: ArgentAccountEvent) {
            let mut contract = self.get_contract_mut();
            contract.emit_event_callback(event);
        }

        fn finalize_migration(ref self: ComponentState<TContractState>) {
            let mut contract = self.get_contract_mut();
            contract.finalize_migration();
        }

        fn migrate_owner(ref self: ComponentState<TContractState>, signer_storage_value: SignerStorageValue) {
            let mut contract = self.get_contract_mut();
            contract.migrate_owner(signer_storage_value);
        }
    }
}
