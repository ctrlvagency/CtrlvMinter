module minter_module::ctrlv_minting {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_std::table::{Self, Table};
    use aptos_token::token::{Self, TokenDataId};
    use aptos_framework::coin;
    use aptos_framework::resource_account;

    use aptos_framework::aptos_coin::AptosCoin;

    const ECOLLECTION_NAME_IN_USE: u64 = 1;

    struct CollectionId has store, copy, drop {
        collection_name: String,
    }

    struct TokenMintingEvent has drop, store {
        token_receiver_address: address,
        token_data_id: TokenDataId,
        collection_id: CollectionId,
    }

    struct CollectionTokenMinter has store {
        admin: address,
        token_data_id: TokenDataId,
        minting_enabled: bool,
        token_minting_events: EventHandle<TokenMintingEvent>,
        mint_price: u64,
        minted_count: u64,
        supply: u64
    }

    struct CollectionTokenMinterStore has key {
        signer_cap: account::SignerCapability,
        minters: Table<CollectionId,CollectionTokenMinter>,
    }

    fun init_module(resource_account: &signer) {
        let resource_signer_cap = resource_account::retrieve_resource_account_cap(resource_account, @source_addr); //??

        //Create the Minter Store
        move_to(resource_account, CollectionTokenMinterStore {
            signer_cap: resource_signer_cap,
            minters: table::new<CollectionId,CollectionTokenMinter>(),
        });
    }

    public entry fun create_collection(
        creator: &signer, 
        collection_name: String,
        description: String, 
        collection_uri: String, 
        token_name: String, 
        token_uri: String,
        mint_price: u64,
        supply: u64,
    ) acquires CollectionTokenMinterStore
    {
        let collection_id = CollectionId { collection_name };

        let minter_store = borrow_global_mut<CollectionTokenMinterStore>(@minter_module);
        let resource_signer = account::create_signer_with_capability(&minter_store.signer_cap);
        
        //Check to see if we've already created this collection...
        assert!(!table::contains(&minter_store.minters, collection_id), error::invalid_argument(ECOLLECTION_NAME_IN_USE));

        //Creation price?
        //Ladder pricing for minting?

        let maximum_supply = 0;
        let mutate_setting = vector<bool>[ true, true, true ];
        let creater_account_address = signer::address_of(creator);
        token::create_collection(&resource_signer, collection_name, description, collection_uri, maximum_supply, mutate_setting);
        
        let token_data_id = token::create_tokendata(
            &resource_signer,
            collection_name,
            token_name,
            string::utf8(b""),
            0,
            token_uri,
            //TODO ROYALTY SYSTEM??
            creater_account_address,
            1,
            0,
            // we don't allow any mutation to the token
            token::create_token_mutability_config(
                &vector<bool>[ true, true, true, true, true ]
            ),
            vector::empty<String>(),
            vector::empty<vector<u8>>(),
            vector::empty<String>(),
        );

        table::add(&mut minter_store.minters, collection_id,  CollectionTokenMinter {
            admin: signer::address_of(creator),
            token_data_id,
            minting_enabled: true,
            token_minting_events: account::new_event_handle<TokenMintingEvent>(&resource_signer),
            mint_price,
            minted_count: 0,
            supply,
        });
    }

    public entry fun mint_nft(receiver: &signer, collection: CollectionId) acquires CollectionTokenMinterStore,
    {
        let receiver_addr = signer::address_of(receiver);

        let minter_store = borrow_global_mut<CollectionTokenMinterStore>(@minter_module);

        let minter = table::borrow_mut(
            &mut minter_store.minters,
            collection,
        );

        //Pull out the coins from the minter
        let coins = coin::withdraw<AptosCoin>(receiver, minter.mint_price);

        // mint token to the receiver
        let resource_signer = account::create_signer_with_capability(&minter_store.signer_cap);
        let token_id = token::mint_token(&resource_signer, minter.token_data_id, 1);
        token::direct_transfer(&resource_signer, receiver, token_id, 1);

        //TODO: We need to permutate the token uri here. Aptos doesn't look like it has the ERC720 url syntax

        event::emit_event<TokenMintingEvent>(
            &mut minter.token_minting_events,
            TokenMintingEvent {
                token_receiver_address: receiver_addr,
                token_data_id: minter.token_data_id,
                collection_id: collection,
            }
        );

        // mutate the token properties to update the property version of this token (???)
        let (creator_address, collection, name) = token::get_token_data_id_fields(&minter.token_data_id);
        token::mutate_token_properties(
            &resource_signer,
            receiver_addr,
            creator_address,
            collection,
            name,
            0,
            1,
            vector::empty<String>(),
            vector::empty<vector<u8>>(),
            vector::empty<String>(),
        );

        //Pay the admin of the minter
        coin::deposit<AptosCoin>(minter.admin, coins);
    }
}