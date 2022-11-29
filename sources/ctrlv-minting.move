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
    const ENONE_LEFT: u64 = 2;
    const ECOLLECTION_NOT_FOUND: u64 = 3;
    const EINSUFFICIENT_PERMISSIONS: u64 = 4;

    struct TokenMintingEvent has drop, store {
        token_receiver_address: address,
        token_data_id: TokenDataId,
        collection: String,
    }

    struct CollectionTokenMinter has store {
        admin: address,
        collection: String,
        token_base_name: String,
        token_base_uri: String,
        minting_enabled: bool,
        token_minting_events: EventHandle<TokenMintingEvent>,
        mint_price: u64,
        platform_cut: u64,
        minted_count: u64,
        supply: u64
    }

    struct CollectionTokenMinterStore has key {
        signer_cap: account::SignerCapability,
        fee_address: address,
        minters: Table<String, CollectionTokenMinter>,
    }

    fun init_module(resource_account: &signer) {
        let resource_signer_cap = resource_account::retrieve_resource_account_cap(resource_account, @source_addr); //??

        //Create the Minter Store
        move_to(resource_account, CollectionTokenMinterStore {
            signer_cap: resource_signer_cap,
            fee_address: @source_addr,
            minters: table::new<String, CollectionTokenMinter>(),
        });
    }

    public entry fun create_collection(
        creator: &signer, 
        collection: String,
        description: String, 
        collection_uri: String, 
        token_base_name: String, 
        token_base_uri: String,
        mint_price: u64,
        supply: u64,
    ) acquires CollectionTokenMinterStore
    {
        let minter_store = borrow_global_mut<CollectionTokenMinterStore>(@minter_module);
        let resource_signer = account::create_signer_with_capability(&minter_store.signer_cap);
        
        //Check to see if we've already created this collection...
        assert!(!table::contains(&minter_store.minters, collection), error::invalid_argument(ECOLLECTION_NAME_IN_USE));

        let maximum_supply = 0;
        let mutate_setting = vector<bool>[ true, true, true ];
        let creater_account_address = signer::address_of(creator);
        token::create_collection(&resource_signer, collection, description, collection_uri, maximum_supply, mutate_setting);

        let platform_cut = mint_price / 20; // 1/20 = 5%

        table::add(&mut minter_store.minters, collection,  CollectionTokenMinter {
            admin: creater_account_address,
            collection,
            token_base_name,
            token_base_uri,
            minting_enabled: true,
            token_minting_events: account::new_event_handle<TokenMintingEvent>(&resource_signer),
            mint_price,
            platform_cut,
            minted_count: 0,
            supply,
        });
    }

    /// @dev Converts a `u128` to its `ascii::String` decimal representation.
    fun to_string(value: u64): String {
        if (value == 0) {
            return string::utf8(b"0")
        };
        let buffer = vector::empty<u8>();
        while (value != 0) {
            vector::push_back(&mut buffer, ((48 + value % 10) as u8));
            value = value / 10;
        };
        vector::reverse(&mut buffer);
        string::utf8(buffer)
    }

    public entry fun mint_nft(receiver: &signer, collection: String) acquires CollectionTokenMinterStore,
    {
        let receiver_addr = signer::address_of(receiver);

        let minter_store = borrow_global_mut<CollectionTokenMinterStore>(@minter_module);

        let minter = table::borrow_mut(
            &mut minter_store.minters,
            collection,
        );

        //Make sure we have NFTs left to mint before we do anything.
        assert!(minter.minted_count < minter.supply, error::invalid_argument(ENONE_LEFT));

        let resource_signer = account::create_signer_with_capability(&minter_store.signer_cap);
        let resource_signer_address = signer::address_of(&resource_signer);

        //Pull out the coins from the minter
        let coins = coin::withdraw<AptosCoin>(receiver, minter.mint_price);

        // Now the coins are in hand, it's safe to start the mint
        // Increment the number minted from the collection.
        minter.minted_count = minter.minted_count + 1;

        // Template the name and URI off their base values
        let mint_number = minter.minted_count; //Use number after increment so our numbers start at 1
        let num_str = to_string(mint_number);
        let token_name = minter.token_base_name;
        string::append(&mut token_name, num_str);
        let token_uri = minter.token_base_uri;
        string::append(&mut token_uri, num_str);
        string::append(&mut token_uri, string::utf8(b".json"));

        //Create tokendata for this new NFT from the collection        
        let token_data_id = token::create_tokendata(
            &resource_signer,
            minter.collection,
            token_name,
            string::utf8(b""), 
            1,
            token_uri,
            minter.admin, //Put the admin of the collection as the royalty receiver.
            1,
            0,
            // we don't allow any mutation to the token
            token::create_token_mutability_config(
                &vector<bool>[ false, false, false, false, true ]
            ),
            vector::empty<String>(),
            vector::empty<vector<u8>>(),
            vector::empty<String>(),
        );

        
        // Mint a token from this new data_id, this will have a property version of 0
        // Tokens with a property version of 0 are fungible. We will need to mutate it to make it an NFT
        let fungible_token_id = token::mint_token(&resource_signer, token_data_id, 1);
    
        // Mutate the token properties to their exact values to update the property version of this token.
        // This converts the token from fungible into non-fungible since property versions of a token only change once.
        let token_id = token::mutate_one_token(
            &resource_signer,
            resource_signer_address,
            fungible_token_id,
            vector::empty<String>(),
            vector::empty<vector<u8>>(),
            vector::empty<String>(),
        );

        // Send the now non-fungible token to the receiver
        token::direct_transfer(&resource_signer, receiver, token_id, 1);

        event::emit_event<TokenMintingEvent>(
            &mut minter.token_minting_events,
            TokenMintingEvent {
                token_receiver_address: receiver_addr,
                token_data_id: token_data_id,
                collection: collection,
            }
        );

        // Split out the platform cut
        let platform_cut = coin::extract(&mut coins, minter.platform_cut);

        //Pay the admin of the minter
        coin::deposit<AptosCoin>(minter.admin, coins);
        coin::deposit<AptosCoin>(minter_store.fee_address, platform_cut);

    }

    
    public entry fun change_collection_info(
        creator: &signer, 
        collection: String,
        token_base_name: String, 
        token_base_uri: String,
        mint_price: u64,
        supply: u64,
    ) acquires CollectionTokenMinterStore
    {
        let minter_store = borrow_global_mut<CollectionTokenMinterStore>(@minter_module);
        //let resource_signer = account::create_signer_with_capability(&minter_store.signer_cap);

        assert!(table::contains(&minter_store.minters, collection), error::invalid_argument(ECOLLECTION_NOT_FOUND));

        let minter = table::borrow_mut(
            &mut minter_store.minters,
            collection,
        );

        assert!(signer::address_of(creator) == minter.admin, error::permission_denied(EINSUFFICIENT_PERMISSIONS));

        minter.supply = supply;
        minter.mint_price = mint_price;
        minter.token_base_name = token_base_name;
        minter.token_base_uri = token_base_uri;

        //These don't seem to be avaialable...
        /*token::mutate_collection_description(&resource_signer, collection, description);
        token::mutate_collection_uri(&resource_signer, collection, collection_uri);
        token::mutate_collection_maximum(&resource_signer, collection, supply);*/
    }
}