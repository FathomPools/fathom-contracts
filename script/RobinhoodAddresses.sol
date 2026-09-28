// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Live Robinhood Chain (4663) addresses used by deploy scripts and fork tests.
/// Feeds: Chainlink RDD `feeds-robinhood-mainnet.json` (8 decimals, 86,400 s heartbeat).
/// Token addresses: Robinhood registry `api.robinhood.com/rhj/assets` (chainId 4663 deployment).
/// Every stock token that has a Chainlink feed is listed (35 of 194 tokens, checked 2026-09-04:
/// each token has code and each feed answered a positive price < 24 h old). Roughly largest first;
/// index 0 must stay NVDA (fork tests read `stocks()[0]`).
library RobinhoodAddresses {
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    uint48 internal constant HEARTBEAT = 90_000; // > 24 h feed heartbeat
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;

    struct StockQuote {
        string symbol;
        address token;
        address feed;
    }

    function stocks() internal pure returns (StockQuote[] memory s) {
        s = new StockQuote[](35);
        s[0] =
            StockQuote("NVDA", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15);
        s[1] =
            StockQuote("MSFT", 0xe93237C50D904957Cf27E7B1133b510C669c2e74, 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E);
        s[2] =
            StockQuote("AAPL", 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0);
        s[3] =
            StockQuote("GOOGL", 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 0xF6f373a037c30F0e5010d854385cA89185AE638b);
        s[4] =
            StockQuote("AMZN", 0x12f190a9F9d7D37a250758b26824B97CE941bF54, 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C);
        s[5] =
            StockQuote("META", 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, 0x7C38C00C30BEe9378381E7B6135d7283356D71b1);
        s[6] = StockQuote("TSM", 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA, 0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F);
        s[7] =
            StockQuote("TSLA", 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 0x4A1166a659A55625345e9515b32adECea5547C38);
        s[8] = StockQuote("SPY", 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 0x319724394D3A0e3669269846abE664Cd621f9f6A);
        s[9] =
            StockQuote("ORCL", 0xb0992820E760d836549ba69BC7598b4af75dEE03, 0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844);
        s[10] =
            StockQuote("ASML", 0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA, 0xB4106147E8cce40b7d46124090d373A71b70f87D);
        s[11] =
            StockQuote("PLTR", 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c);
        s[12] =
            StockQuote("QQQ", 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, 0x80901d846d5D7B030F26B480776EE3b29374C2ae);
        s[13] =
            StockQuote("BABA", 0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4, 0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984);
        s[14] =
            StockQuote("AMD", 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72);
        s[15] = StockQuote("MU", 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596);
        s[16] =
            StockQuote("INTC", 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681, 0x3f390C5C24628Ac7C489515402235FeAD71D1913);
        s[17] =
            StockQuote("DELL", 0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd, 0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b);
        s[18] =
            StockQuote("COIN", 0x6330D8C3178a418788dF01a47479c0ce7CCF450b, 0xA3a468A452940B7D6b69991207B508c609a98Ef2);
        s[19] =
            StockQuote("MSTR", 0xec262a75e413fAfD0dF80480274532C79D42da09, 0x396118bdFB181e6240E74D243F266B061c0edc3D);
        s[20] =
            StockQuote("SGOV", 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5, 0xa0DF4ee0fFf975306345875E3548Fcc519577A11);
        s[21] =
            StockQuote("SNDK", 0xB90A19fF0Af67f7779afF50A882A9CfF42446400, 0xfb133Fa4B7b385802B693a293606682Df47109A3);
        s[22] =
            StockQuote("SLV", 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f, 0x209b73908e92Ae021826eD79609845451Ecba2ce);
        s[23] =
            StockQuote("RKLB", 0x3b14C39E89D60D627b42a1A4CA45b5bb45Fc12e2, 0x045477BF65Aef6f4F2386ad0164579e48381CC74);
        s[24] =
            StockQuote("CRWV", 0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3, 0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C);
        s[25] =
            StockQuote("NBIS", 0x9D9c6684F596F66a64C030B93A886D51Fd4D7931, 0xE1D87B116Ba0fe898998f1D140339D1fA1E09705);
        s[26] =
            StockQuote("CRCL", 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5, 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a);
        s[27] =
            StockQuote("GME", 0x1b0E319c6A659F002271B69dB8A7df2F911c153E, 0x27C71df6A64fB476468EdF256CF72c038baB5B67);
        s[28] =
            StockQuote("IONQ", 0x558378E000D634A36593E338eBacdd6207640EfE, 0x22EfeC4919baf55F360E0EDee4AbEB26DE4971eb);
        s[29] =
            StockQuote("EWY", 0x7f0aBeF0C07280F82c6a08ead09dEd6BAE2C13Fc, 0xEFdf54610B62A7753Ec30bDc380847c12D32e1D1);
        s[30] =
            StockQuote("USO", 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344, 0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c);
        s[31] =
            StockQuote("CLSK", 0xcBB95BBF36099d34dA091dc6Fa6F49EfA257Cee3, 0x810c12D3a554Bc47fd39597Fe3b3AAC4941F50eF);
        s[32] =
            StockQuote("RGTI", 0x284358abc07F9359f19f4b5b4aC91901Be2597Ba, 0x2A045cF1C49c61c166C036d2f06FA2D2d984f765);
        s[33] =
            StockQuote("SPCX", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb);
        s[34] =
            StockQuote("USAR", 0xd917B029C761D264c6A312BBbcDA868658eF86a6, 0xA994d3684e8400A6c8078226925779FdeE682DD9);
    }
}
