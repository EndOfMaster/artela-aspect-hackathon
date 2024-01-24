require("@nomicfoundation/hardhat-toolbox");
require('hardhat-deploy');
require('dotenv').config();

const privateKey = process.env.PRIVATE_KEY ?? "NO_PRIVATE_KEY";
const scanKey = process.env.ETHERSCAN_API_KEY ?? "ETHERSCAN_API_KEY";

task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  networks: {
    hardhat: {
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./test",
    deploy: "./scripts/deploy",
    deployments: "./deployments",
  },
  namedAccounts: {
    deployer: 0
  },
};
