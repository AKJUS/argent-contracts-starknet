use argent::signer::signer_signature::{Signer, SignerSignature, SignerStorageValue, SignerStorageTrait, SignerType};
use argent::utils::linked_set::LinkedSetConfig;
use starknet::storage::StoragePath;

impl SignerStorageValueLinkedSetConfig of LinkedSetConfig<SignerStorageValue> {
    const END_MARKER: SignerStorageValue =
        SignerStorageValue { stored_value: 'end', signer_type: SignerType::Starknet };

    #[inline(always)]
    fn is_valid_item(self: @SignerStorageValue) -> bool {
        *self.stored_value != 0 && *self.stored_value != Self::END_MARKER.stored_value
    }

    #[inline(always)]
    fn hash(self: @SignerStorageValue) -> felt252 {
        (*self).into_guid()
    }

    #[inline(always)]
    fn path_read_value(path: StoragePath<SignerStorageValue>) -> Option<SignerStorageValue> {
        let stored_value = path.stored_value.read();
        if stored_value == 0 || stored_value == Self::END_MARKER.stored_value {
            return Option::None;
        }
        let signer_type = path.signer_type.read();
        Option::Some(SignerStorageValue { stored_value, signer_type })
    }

    #[inline(always)]
    fn path_is_in_set(path: StoragePath<SignerStorageValue>) -> bool {
        // Items in the set point to the next item or the end marker. Items outside the set point to uninitialized
        // storage
        path.stored_value.read() != 0
    }
}

#[starknet::interface]
pub trait IOwnerManager<TContractState> {
    /// @notice Returns the guid of all the owners
    fn get_owner_guids(self: @TContractState) -> Array<felt252>;
    fn is_owner(self: @TContractState, owner: Signer) -> bool;
    fn is_owner_guid(self: @TContractState, owner_guid: felt252) -> bool;

    /// @notice Verifies whether a provided signature is valid and comes from one of the owners.
    /// @param hash Hash of the message being signed
    /// @param owner_signature Signature to be verified
    #[must_use]
    fn is_valid_owner_signature(self: @TContractState, hash: felt252, owner_signature: SignerSignature) -> bool;
}

#[starknet::interface]
trait IOwnerManagerInternal<TContractState> {
    fn initialize(ref self: TContractState, owner: Signer);
    fn initialize_from_upgrade(ref self: TContractState, signer_storage: SignerStorageValue);
    /// @notice Adds new owners to the account
    /// @dev will revert when trying to add a signer is already an owner
    /// @param owners_to_add An array with all the signers to add
    fn add_owners(ref self: TContractState, owners_to_add: Array<Signer>);

    /// @notice Removes owners
    /// @dev Will revert if any of the signers is not an owner
    /// @param owners_to_remove All the signers to remove
    fn remove_owners(ref self: TContractState, owner_guids_to_remove: Array<felt252>);
    fn is_valid_owners_replacement(self: @TContractState, new_single_owner: Signer) -> bool;
    fn replace_all_owners_with_one(ref self: TContractState, new_single_owner: SignerStorageValue);
    fn assert_valid_storage(self: @TContractState);
    fn get_single_stark_owner_pubkey(self: @TContractState) -> Option<felt252>;
    fn get_single_owner(self: @TContractState) -> Option<SignerStorageValue>;
}

/// Managing the list of owners of the account
#[starknet::component]
mod owner_manager_component {
    use argent::account::interface::{IEmitArgentAccountEvent};
    use argent::multiowner_account::argent_account::ArgentAccount::Event as ArgentAccountEvent;
    use argent::multiowner_account::events::{SignerLinked, OwnerAddedGuid, OwnerRemovedGuid};
    use argent::signer::signer_signature::{
        Signer, SignerTrait, SignerSignature, SignerSignatureTrait, SignerSpanTrait, SignerStorageValue,
        SignerStorageTrait
    };
    use argent::utils::linked_set_with_head::{
        LinkedSetWithHead, LinkedSetWithHeadReadImpl, LinkedSetWithHeadWriteImpl, MutableLinkedSetWithHeadReadImpl
    };

    use argent::utils::{transaction_version::is_estimate_transaction, asserts::assert_only_self};
    use super::{IOwnerManager, IOwnerManagerInternal, SignerStorageValueLinkedSetConfig};
    /// Too many owners could make the account unable to process transactions if we reach a limit
    const MAX_SIGNERS_COUNT: usize = 32;

    #[storage]
    struct Storage {
        owners_storage: LinkedSetWithHead<SignerStorageValue>
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OwnerAddedGuid: OwnerAddedGuid,
        OwnerRemovedGuid: OwnerRemovedGuid,
    }

    #[embeddable_as(OwnerManagerImpl)]
    impl OwnerManager<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>, +IEmitArgentAccountEvent<TContractState>
    > of IOwnerManager<ComponentState<TContractState>> {
        fn get_owner_guids(self: @ComponentState<TContractState>) -> Array<felt252> {
            self.owners_storage.get_all_hashes()
        }

        #[inline(always)]
        fn is_owner(self: @ComponentState<TContractState>, owner: Signer) -> bool {
            self.owners_storage.contains(owner.storage_value())
        }

        #[inline(always)]
        fn is_owner_guid(self: @ComponentState<TContractState>, owner_guid: felt252) -> bool {
            self.owners_storage.contains_by_hash(owner_guid)
        }

        #[must_use]
        fn is_valid_owner_signature(
            self: @ComponentState<TContractState>, hash: felt252, owner_signature: SignerSignature
        ) -> bool {
            if !self.is_owner(owner_signature.signer()) {
                return false;
            }
            return owner_signature.is_valid_signature(hash) || is_estimate_transaction();
        }
    }

    #[embeddable_as(OwnerManagerInternalImpl)]
    impl OwnerManagerInternal<
        TContractState, +HasComponent<TContractState>, +IEmitArgentAccountEvent<TContractState>, +Drop<TContractState>
    > of IOwnerManagerInternal<ComponentState<TContractState>> {
        fn initialize(ref self: ComponentState<TContractState>, owner: Signer) {
            let guid = self.owners_storage.insert(owner.storage_value());
            self.emit_signer_linked_event(SignerLinked { signer_guid: guid, signer: owner });
            self.emit_owner_added(guid);
        }

        fn initialize_from_upgrade(ref self: ComponentState<TContractState>, signer_storage: SignerStorageValue) {
            // We don't want to emit any events in this case
            assert(self.owners_storage.len() == 0, 'argent/already-initialized');
            self.owners_storage.insert(signer_storage);
        }

        fn add_owners(ref self: ComponentState<TContractState>, owners_to_add: Array<Signer>) {
            let owner_len = self.owners_storage.len();

            self.assert_valid_owner_count(owner_len + owners_to_add.len());
            for owner in owners_to_add {
                let owner_guid = self.owners_storage.insert(owner.storage_value());
                self.emit_owner_added(owner_guid);
                self.emit_signer_linked_event(SignerLinked { signer_guid: owner_guid, signer: owner });
            };
        }

        fn remove_owners(ref self: ComponentState<TContractState>, owner_guids_to_remove: Array<felt252>) {
            self.assert_valid_owner_count(self.owners_storage.len() - owner_guids_to_remove.len());

            for guid in owner_guids_to_remove {
                self.owners_storage.remove(guid);
                self.emit_owner_removed(guid);
            };
        }

        fn assert_valid_storage(self: @ComponentState<TContractState>) {
            self.assert_valid_owner_count(self.owners_storage.len());
        }

        fn get_single_owner(self: @ComponentState<TContractState>) -> Option<SignerStorageValue> {
            self.owners_storage.single() // TODO consider returning .first() instead for better performance
        }

        fn get_single_stark_owner_pubkey(self: @ComponentState<TContractState>) -> Option<felt252> {
            self.get_single_owner()?.starknet_pubkey_or_none()
        }

        fn is_valid_owners_replacement(self: @ComponentState<TContractState>, new_single_owner: Signer) -> bool {
            !self.is_owner(new_single_owner)
        }

        fn replace_all_owners_with_one(ref self: ComponentState<TContractState>, new_single_owner: SignerStorageValue) {
            let new_owner_guid = new_single_owner.into_guid();
            let current_owners = self.owners_storage.get_all_hashes();
            for current_owner_guid in current_owners {
                assert(current_owner_guid != new_owner_guid, 'argent/already-an-owner');
                self.owners_storage.remove(current_owner_guid);
                self.emit_owner_removed(current_owner_guid);
            };
            self.owners_storage.insert(new_single_owner);
            self.emit_owner_added(new_owner_guid);
        }
    }

    #[generate_trait]
    impl Private<
        TContractState, +HasComponent<TContractState>, +IEmitArgentAccountEvent<TContractState>, +Drop<TContractState>
    > of PrivateTrait<TContractState> {
        fn assert_valid_owner_count(self: @ComponentState<TContractState>, signers_len: usize) {
            assert(signers_len != 0, 'argent/invalid-signers-len');
            assert(signers_len <= MAX_SIGNERS_COUNT, 'argent/invalid-signers-len');
        }
        fn emit_signer_linked_event(ref self: ComponentState<TContractState>, event: SignerLinked) {
            let mut contract = self.get_contract_mut();
            contract.emit_event_callback(ArgentAccountEvent::SignerLinked(event));
        }
        fn emit_owner_added(ref self: ComponentState<TContractState>, new_owner_guid: felt252) {
            self.emit(OwnerAddedGuid { new_owner_guid });
        }
        fn emit_owner_removed(ref self: ComponentState<TContractState>, removed_owner_guid: felt252) {
            self.emit(OwnerRemovedGuid { removed_owner_guid });
        }
    }
}
