// const { BN } = require('@openzeppelin/test-helpers');
const fixed_addrs = require('./fixed_addrs.json');
const Migrations = artifacts.require("Migrations");
const Vat = artifacts.require('Vat');
const GemJoin = artifacts.require('GemJoin');
const DaiJoin = artifacts.require('DaiJoin');
const Weth = artifacts.require("WETH9");
const Dai = artifacts.require("TestDai");
const Pot = artifacts.require('Pot');
const End = artifacts.require('End');
const Chai = artifacts.require('Chai');
const { BigNumber } = require("ethers");

function toRay(value) {
  let exponent = BigNumber.from(10).pow(BigNumber.from(17))
  return BigNumber.from((value) * 10 ** 10).mul(exponent)
}

function toRad(value) {
  let exponent = BigNumber.from(10).pow(BigNumber.from(35))
  return BigNumber.from((value) * 10 ** 10).mul(exponent)
}

function subBN(x, y) {
  return BigNumber.from(x).sub(BigNumber.from(y))
}

module.exports = async (deployer, network, accounts) => {
  const migrations = await Migrations.deployed();

  let vatAddress;
  let wethAddress;
  let wethJoinAddress;
  let daiAddress;
  let daiJoinAddress;
  let potAddress;
  let endAddress;
  let chaiAddress;

  if (network === "development") {
    // Setting up Vat
    const WETH = web3.utils.fromAscii("ETH-A");
    const Line = web3.utils.fromAscii("Line");
    const spotName = web3.utils.fromAscii("spot");
    const linel = web3.utils.fromAscii("line");

    const limits = toRad(10000);
    const spot  = toRay(150);

    // Setup vat
    await deployer.deploy(Vat);
    const vat = await Vat.deployed();
    vatAddress = vat.address;
    await vat.init(WETH);
    await vat.file(WETH, spotName, spot);
    await vat.file(WETH, linel, limits);
    await vat.file(Line, limits);

    await deployer.deploy(Weth);
    wethAddress = (await Weth.deployed()).address;

    await deployer.deploy(GemJoin, vatAddress, WETH, wethAddress);
    wethJoinAddress = (await GemJoin.deployed()).address;

    await deployer.deploy(Dai, 0);
    daiAddress = (await Dai.deployed()).address;

    await deployer.deploy(DaiJoin, vatAddress, daiAddress);
    daiJoinAddress = (await DaiJoin.deployed()).address;

    // Setup pot
    await deployer.deploy(Pot, vatAddress);
    const pot = await Pot.deployed();
    potAddress = pot.address;

    // Setup end
    await deployer.deploy(End)
    const end = await End.deployed();
    endAddress = end.address;
    await end.file(web3.utils.fromAscii("vat"), vatAddress);

    // Permissions
    await vat.rely(vatAddress);
    await vat.rely(wethJoinAddress);
    await vat.rely(daiJoinAddress);
    await vat.rely(potAddress);
    await vat.rely(endAddress);

    // Set development environment
    const rate  = toRay(1.25);
    const chi = toRay(1.2);
    await vat.fold(WETH, vatAddress, subBN(rate, toRay(1)));
    await pot.setChi(chi);
  } else {
    vatAddress = fixed_addrs[network].vatAddress;
    wethAddress = fixed_addrs[network].wethAddress;
    wethJoinAddress = fixed_addrs[network].wethJoinAddress;
    daiAddress = fixed_addrs[network].daiAddress;
    daiJoinAddress = fixed_addrs[network].daiJoinAddress;
    potAddress = fixed_addrs[network].potAddress;
    endAddress = fixed_addrs[network].endAddress;
    fixed_addrs[network].chaiAddress && (chaiAddress = fixed_addrs[network].chaiAddress);
  };

  if (network === "mainnet" && network === "kovan" && network === "kovan-fork") {
    chaiAddress = fixed_addrs[network].chaiAddress;
  } else {
    await deployer.deploy(
      Chai,
      vatAddress,
      potAddress,
      daiJoinAddress,
      daiAddress,
    );
    chaiAddress = (await Chai.deployed()).address;
  }

  // Commit addresses to migrations registry
  const deployedExternal = {
    'Vat': vatAddress,
    'Weth': wethAddress,
    'WethJoin': wethJoinAddress,
    'Dai': daiAddress,
    'DaiJoin': daiJoinAddress,
    'Pot': potAddress,
    'End': endAddress,
    'Chai': chaiAddress,
  }

  for (name in deployedExternal) {
    await migrations.register(web3.utils.fromAscii(name), deployedExternal[name]);
  }
  console.log(deployedExternal)
}
