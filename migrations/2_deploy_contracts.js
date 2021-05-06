const Router = artifacts.require("FoxchainRouter");

module.exports = function (deployer, network) {
  let WBNB_ADDRESS;
  const FACTORY_ADDRESS = process.env.REACT_APP_FACTORY_ADDRESS;
  if (network === 'mainnet') {
    WBNB_ADDRESS = process.env.REACT_APP_WBNB_MAINNET_ADDRESS;
  } else {
    WBNB_ADDRESS = REACT_APP_WBNB_TESTNET_ADDRESS;
  }
  await deployer.deploy(Router, FACTORY_ADDRESS, WBNB_ADDRESS);
};
