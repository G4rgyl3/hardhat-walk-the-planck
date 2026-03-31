const fs = require("node:fs");
const path = require("node:path");

function configureOhlConfigurationDirectory() {
  if (process.env.OHL_CONFIGURATION_DIR) {
    return;
  }

  const configurationCandidates = [
    path.resolve(__dirname, "..", "..", "ohl", "configuration"),
    path.resolve(__dirname, "..", "configuration"),
  ];

  const configurationDirectory = configurationCandidates.find((candidate) =>
    fs.existsSync(path.join(candidate, "contract-index.js"))
  );

  if (configurationDirectory) {
    process.env.OHL_CONFIGURATION_DIR = configurationDirectory;
  }
}

configureOhlConfigurationDirectory();

const { loadSigner, provider, wallet } = require("@ohlabs/sdk/wallet/connect");
//const { addressConfig } = require("@ohlabs/configuration/address.js");
const { CHAIN_SLUGS } = require("@ohlabs/configuration/chain-slugs");
const { Contract } = require("ethers");
//const { Token } = require('@uniswap/sdk-core');
const { Deployer } = require("@ohlabs/sdk/deployment/deploy");
const { Indexer } = require("@ohlabs/sdk/deployment/indexer");
const { Interpolator } = require("@ohlabs/sdk/interpolation/contract-interpolator");

const artifacts = {
	PlanckGame: require("../artifacts/contracts/walk-the-planck.sol/WalkThePlanck.json"),
};

/*
npx hardhat run --network base "./deploy/deploy-game.js"
*/

const buyfee = "0";
const sellfee = "50";
const feeScale = "10000";

const environment = "test";
//"test"
//"production";
//"Arbitrum";

const contractName = "WalkThePlanck";
const contractMetadataName = "Game";
const contractVersion = "0.0.4";
const network = CHAIN_SLUGS.Base;
const useVerify = false;

const collector = "0x1b0823E55Dd618829D4DB98A33Dadc739f6fA41B";
const entropy = "0x41c9e39574f40ad34c79f1c99b66a45efb830d4c"; 

var gameContract;

async function deployGame()
{
	console.log("---Deploying Walk the Planck---");
	gameContract = useVerify ? await Deployer.deployWithVerify
	(
		artifacts.PlanckGame.abi, 
		artifacts.PlanckGame.bytecode, 
		[
			wallet.signer.address,
			collector,
      entropy
		], 
		wallet.signer
	) :
	await Deployer.deployContract
	(
		artifacts.PlanckGame.abi, 
		artifacts.PlanckGame.bytecode, 
		[
			wallet.signer.address,
			collector,
      entropy
		], 
		wallet.signer
	);
	console.log(`${contractName} created at ${gameContract.address}`);
 
	console.log("Publishing contract metadata");
	// Signature: (environment, network, category, name, address, abi, version)
	await Indexer.publishContractMetadata
  (
    environment,
    network,
    contractName,
    contractMetadataName,
    gameContract?.address,
    artifacts.PlanckGame.abi,
    contractVersion, 
  );

	//console.log("Generating settings");
	//await Interpolator.generateSettings(contractName, //gameContract.address, artifacts.PlanckGame.abi);

	console.log("-------------------");
}

async function configure(){ 
  console.log("Building contracts");
  //x9Contract = x9Contract ?? new Contract(addressConfig[environment][network].X9_ADDRESS,artifacts.X9.abi,provider);
  //gameRewardsContract = gameRewardsContract ??  new Contract(addressConfig[environment][network].GAME_REWARDS_ADDRESS, artifacts.GameRewards.abi, provider);
  //rewardsPoolContract = rewardsPoolContract ?? new Contract(addressConfig[environment][network].REWARDS_POOL_ADDRESS, artifacts.RewardsPool.abi, provider);
 
  /* Game scores - deployed */
  gameScoresContract = gameScoresContract ?? new Contract(addressConfig[environment][network].GAME_SCORES_ADDRESS, artifacts.GameScores.abi, provider);
  
  console.log("setting scores signer");
  await gameScoresContract.connect(owner).setSigner('0xf2BACA95743AfCB6EC4d7D714F00f7824eCCE5dE');

  console.log("Building hangar contract");
  hangarContract = hangarContract ?? new Contract(addressConfig[environment][network].HANGAR_ADDRESS,artifacts.Hangar.abi,provider);
  
  console.log("Setting base ship");
  await hangarContract.connect(owner).setBaseShip(baseShipType);

  console.log("Configuring ship settings");
  await hangarContract.connect(owner).addShips(shipSettings);
  //await hangarContract.connect(owner).addShips(newshipSettings);

  console.log("Configuring upgrade settings");
  await hangarContract.connect(owner).addUpgrades(upgradeSettings);
  //await hangarContract.connect(owner).addUpgrades(newupgradeSettings);

  /*
  console.log("Getting ships");
  var ships = await hangarContract.getShips("0xCc4f4c00f3D14Ee1B5bB7814A88B784c829Ba03c");
  console.log(ships);
  */

  /*
  //presale requires ability to mint x9
  console.log("Linking presale -> X9");	
  await x9Contract.connect(owner).addLink(presaleContract.address);
  
  //presale calls admin deposit
  console.log("Linking presale -> vault");	
  await vaultContract.connect(owner).addLink(presaleContract.address);
  
  //why?
  //console.log("Linking vault -> X9");	
  //await x9Contract.connect(owner).addLink(vaultContract.address);
  //

  console.log("Setting router as fee source");
  await x9Contract.setfeePlatform(addressConfig[network].V2_ROUTER_ADDRESS, true);
 
  console.log("Configuring reward tiers");
  await gameRewardsContract.connect(owner).setTiers(scoreTiers, stakeTeirs);
  
  console.log("Linking Rewards Pool -> X9");	
  await x9Contract.connect(owner).addLink(rewardsPoolContract.address);
  
  console.log("Linking Game Rewards -> Rewards Pool");	
  await rewardsPoolContract.connect(owner).addLink(gameRewardsContract.address);
  */

  //console.log("Minting to self")
  //await x9Contract.connect(owner)['mint(uint256)'](ethers.utils.parseEther('50000'));

}

async function blacklist(addresses) {
	gameScoresContract = gameScoresContract ?? new Contract(addressConfig[environment][network].GAME_SCORES_ADDRESS, artifacts.GameScores.abi, provider);
  
	addresses.forEach(async address => {
		console.log("blacklisting " + address);
		await gameScoresContract.connect(owner).addBlacklist(address);
	});

	console.log("clearing " + address);
	await gameScoresContract.connect(owner).removeBlacklist('0xCc4f4c00f3D14Ee1B5bB7814A88B784c829Ba03c');
	await gameScoresContract.connect(owner).removeBlacklist('0xf2BACA95743AfCB6EC4d7D714F00f7824eCCE5dE');
}

async function clear(addresses) {
	gameScoresContract = gameScoresContract ?? new Contract(addressConfig[environment][network].GAME_SCORES_ADDRESS, artifacts.GameScores.abi, provider);
  
	addresses.forEach(async address => {
		console.log("clearing " + address);
		await gameScoresContract.connect(owner).removeBlacklist(address);
	});
}

async function main() {
  console.log("Signing in");
  await loadSigner();
  await deployGame();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
