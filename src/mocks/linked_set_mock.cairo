/// @dev 🚨 This smart contract is a mock implementation and is not meant for actual deployment or use in any live
/// environment. It is solely for testing, educational, or demonstration purposes. Any interactions with this contract
/// will not have real-world consequences or effects on blockchain networks. Please refrain from relying on the
/// functionality of this contract for any production. 🚨
///

#[starknet::component]
mod linked_set_mock {
    use argent::signer::signer_signature::SignerStorageValue;
    use argent::utils::linked_set::LinkedSet;
    use argent::utils::linked_set_plus_one::LinkedSetPlus1;

    #[storage]
    struct Storage {
        linked_set_plus_1: LinkedSetPlus1<SignerStorageValue>,
        linked_set: LinkedSet<SignerStorageValue>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}
}
