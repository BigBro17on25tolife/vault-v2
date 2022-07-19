// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.14;

import "forge-std/src/Test.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20.sol";
import "../../oracles/chainlink/ChainlinkMultiOracle.sol";
import "../../oracles/composite/CompositeMultiOracle.sol";
import "../../oracles/convex/Cvx3CrvOracle.sol";
import "../../oracles/chainlink/AggregatorV3Interface.sol";
import "../../oracles/convex/ICurvePool.sol";
import "../utils/TestConstants.sol";

contract ConvexOracleTest is Test, TestConstants {
    Cvx3CrvOracle public convexOracle;
    ChainlinkMultiOracle public chainlinkMultiOracle;
    CompositeMultiOracle public compositeMultiOracle;
    ICurvePool public curvePool = ICurvePool(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);
    AggregatorV3Interface public daiEthAggregator = AggregatorV3Interface(0x773616E4d11A78F511299002da57A0a94577F1f4);
    AggregatorV3Interface public usdcEthAggregator = AggregatorV3Interface(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4);
    AggregatorV3Interface public usdtEthAggregator = AggregatorV3Interface(0xEe9F2375b4bdF6387aa8265dD4FB8F16512A1d46);

    address public dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        convexOracle = new Cvx3CrvOracle();
        chainlinkMultiOracle = new ChainlinkMultiOracle();
        compositeMultiOracle = new CompositeMultiOracle();
        
        vm.createSelectFork('mainnet', 15044600);
        convexOracle.grantRole(
            convexOracle.setSource.selector, 
            address(this)
        );
        convexOracle.setSource(
            CVX3CRV, 
            ETH, 
            curvePool, 
            daiEthAggregator, 
            usdcEthAggregator, 
            usdtEthAggregator
        );
        chainlinkMultiOracle.grantRole(
            chainlinkMultiOracle.setSource.selector, 
            address(this)
        );
        chainlinkMultiOracle.setSource(
            DAI, 
            ERC20(dai), 
            ETH, 
            ERC20(weth), 
            address(daiEthAggregator)
        );
        chainlinkMultiOracle.setSource(
            USDC, 
            ERC20(usdc), 
            ETH, 
            ERC20(weth), 
            address(usdcEthAggregator)
        );
        bytes4[] memory roles = new bytes4[](2);
        roles[0] = compositeMultiOracle.setSource.selector;
        roles[1] = compositeMultiOracle.setPath.selector;
        compositeMultiOracle.grantRoles(roles, address(this));
        compositeMultiOracle.setSource(
            CVX3CRV, 
            ETH, 
            IOracle(address(convexOracle))
        );
        compositeMultiOracle.setSource(
            DAI, 
            ETH, 
            IOracle(address(chainlinkMultiOracle))
        );
        compositeMultiOracle.setSource(
            USDC, 
            ETH, 
            IOracle(address(chainlinkMultiOracle))
        );
        bytes6[] memory path = new bytes6[](1);
        path[0] = ETH;
        compositeMultiOracle.setPath(DAI, CVX3CRV, path);
        compositeMultiOracle.setPath(USDC, CVX3CRV, path);
    }

    function testCvx3CrvEthConversionAndReverse() public {
        (uint256 cvx3crvEthAmount,) = compositeMultiOracle.peek(CVX3CRV, ETH, WAD);
        assertEq(cvx3crvEthAmount, 893841082516614, "Conversion unsuccessful");
        (uint256 ethCvx3CrvAmount,) = compositeMultiOracle.peek(ETH, CVX3CRV, WAD);
        assertEq(ethCvx3CrvAmount, 1118767104757027995881, "Conversion unsuccessful");
    }

    function testRetrieveDirectPairsConversion() public {
        (uint256 daiEthAmount,) = compositeMultiOracle.peek(DAI, ETH, WAD);
        assertEq(daiEthAmount, 887629605268503, "Conversion unsuccessful");
        (uint256 ethDaiAmount,) = compositeMultiOracle.peek(ETH, DAI, WAD);
        assertEq(ethDaiAmount, 1126596041935200643687, "Conversion unsuccessful");

        (uint256 usdcEthAmount,) = compositeMultiOracle.peek(USDC, ETH, 1e6);
        assertEq(usdcEthAmount, 888934300000000, "Conversion unsuccessful");
        (uint256 ethUsdcAmount,) = compositeMultiOracle.peek(ETH, USDC, WAD);
        assertEq(ethUsdcAmount, 1124942529, "Conversion unsuccessful");
    }

    function testCvx3CrvDaiConversionAndReverse() public {
        (uint256 cvx3crvDaiAmount,) = compositeMultiOracle.peek(CVX3CRV, DAI, WAD);
        assertEq(cvx3crvDaiAmount, 1006997825682292404, "Conversion unsuccessful");
        (uint256 daiCvx3CrvAmount,) = compositeMultiOracle.peek(DAI, CVX3CRV, WAD);
        assertEq(daiCvx3CrvAmount, 993050803582866704, "Conversion unsuccessful");
    }

    function testCvx3CrvUsdcConversionAndReverse() public {
        (uint256 cvx3crvUsdcAmount,) = compositeMultiOracle.peek(CVX3CRV, USDC, WAD);
        assertEq(cvx3crvUsdcAmount, 1005519, "Conversion unsuccessful");
        (uint256 usdcCvx3CrvAmount,) = compositeMultiOracle.peek(USDC, CVX3CRV, 1e6);
        assertEq(usdcCvx3CrvAmount, 994510453130215351, "Conversion unsuccessful");
    }
}