const Router = artifacts.require("FoxchainRouter");
const WBNB = artifacts.require("WBNB.sol");

module.exports = function (deployer, network) {
  let wbnb;
  const FACTORY_ADDRESS = '0xd5fB4762903C72362157FA1E7ff2b585E2C9501d';
  if (network === 'mainnet') {
    wbnb = await WBNB.at('0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c');
  } else {
    wbnb = await WBNB.at('0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd');
  }
  await deployer.deploy(Router, FACTORY_ADDRESS, wbnb.address);
};
