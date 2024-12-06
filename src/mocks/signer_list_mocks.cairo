/// @dev 🚨 This smart contract is a mock implementation and is not meant for actual deployment or use in any live
/// environment. It is solely for testing, educational, or demonstration purposes. Any interactions with this contract
/// will not have real-world consequences or effects on blockchain networks. Please refrain from relying on the
/// functionality of this contract for any production. 🚨
#[starknet::contract]
mod SignerListMock {
    use argent::multisig_account::signer_storage::signer_list::{
        signer_list_component, signer_list_component::SignerListInternalImpl
    };

    component!(path: signer_list_component, storage: signer_list, event: SignerListEvents);
    // To avoid even any issue, we should prob not even write the impl UNLESS we want to expose it and rather import the
    // impl.
    #[storage]
    struct Storage {
        #[substorage(v0)]
        signer_list: signer_list_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SignerListEvents: signer_list_component::Event,
    }
}
