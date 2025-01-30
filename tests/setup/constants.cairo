use argent::signer::signer_signature::{Signer, SignerTrait, StarknetSignature, starknet_signer_from_pubkey};
use snforge_std::signature::{KeyPairTrait, stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl}};

#[derive(Drop, Serde, Copy)]
struct KeyAndSig {
    pubkey: felt252,
    sig: StarknetSignature,
}

const ARGENT_ACCOUNT_ADDRESS: felt252 = 0x222222222;

const tx_hash: felt252 = 0x2d6479c0758efbb5aa07d35ed5454d728637fceab7ba544d3ea95403a5630a8;

fn OWNER() -> KeyAndSig {
    let new_owner = KeyPairTrait::from_secret_key('OWNER');
    let (r, s): (felt252, felt252) = new_owner.sign(tx_hash).unwrap();
    KeyAndSig { pubkey: new_owner.public_key, sig: StarknetSignature { r, s } }
}

fn MULTISIG_OWNER(key: felt252) -> KeyAndSig {
    let new_owner = KeyPairTrait::from_secret_key(key);
    let (r, s): (felt252, felt252) = new_owner.sign(tx_hash).unwrap();
    KeyAndSig { pubkey: new_owner.public_key, sig: StarknetSignature { r, s } }
}

fn GUARDIAN() -> KeyAndSig {
    let new_owner = KeyPairTrait::from_secret_key('GUARDIAN');
    let (r, s): (felt252, felt252) = new_owner.sign(tx_hash).unwrap();
    KeyAndSig { pubkey: new_owner.public_key, sig: StarknetSignature { r, s } }
}

fn WRONG_OWNER() -> KeyAndSig {
    let new_owner = KeyPairTrait::from_secret_key('WRONG_OWNER');
    let (r, s): (felt252, felt252) = new_owner.sign(tx_hash).unwrap();
    KeyAndSig { pubkey: new_owner.public_key, sig: StarknetSignature { r, s } }
}

fn WRONG_GUARDIAN() -> KeyAndSig {
    let new_owner = KeyPairTrait::from_secret_key('WRONG_GUARDIAN');
    let (r, s): (felt252, felt252) = new_owner.sign(tx_hash).unwrap();
    KeyAndSig { pubkey: new_owner.public_key, sig: StarknetSignature { r, s } }
}

fn SIGNER_1() -> Signer {
    starknet_signer_from_pubkey(MULTISIG_OWNER(1).pubkey)
}

fn SIGNER_2() -> Signer {
    starknet_signer_from_pubkey(MULTISIG_OWNER(2).pubkey)
}

fn SIGNER_3() -> Signer {
    starknet_signer_from_pubkey(MULTISIG_OWNER(3).pubkey)
}

fn SIGNER_4() -> Signer {
    starknet_signer_from_pubkey(MULTISIG_OWNER(4).pubkey)
}
