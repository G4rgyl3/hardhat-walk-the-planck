const { expect } = require("chai");

describe("WalkThePlanck", function () {
  const ENTRY_FEE = ethers.utils.parseEther("0.001");
  const OTHER_ENTRY_FEE = ethers.utils.parseEther("0.005");
  const NEW_ENTRY_FEE = ethers.utils.parseEther("0.02");

  async function deployFixture() {
    const [owner, treasury, playerOne, playerTwo, playerThree, provider] = await ethers.getSigners();

    const MockEntropy = await ethers.getContractFactory("TestMockEntropy");
    const entropy = await MockEntropy.deploy(provider.address);
    await entropy.deployed();

    const WalkThePlanck = await ethers.getContractFactory("WalkThePlanck");
    const game = await WalkThePlanck.deploy(owner.address, treasury.address, entropy.address);
    await game.deployed();

    return { game, entropy, owner, treasury, playerOne, playerTwo, playerThree };
  }

  async function increaseTime(seconds) {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine", []);
  }

  function normalizeBuckets(buckets) {
    return buckets.map((bucket) => ({
      matchId: bucket.matchId.toString(),
      maxPlayers: Number(bucket.maxPlayers),
      playerCount: Number(bucket.playerCount),
      entryFee: bucket.entryFee.toString(),
      deadline: bucket.deadline.toString(),
      status: Number(bucket.status),
      players: [...bucket.players],
    }));
  }

  describe("active match bucket views", function () {
    it("returns active buckets for open matches", async function () {
      const { game, playerOne, playerTwo } = await deployFixture();

      await game.connect(playerOne).joinQueue(2, ENTRY_FEE, { value: ENTRY_FEE });
      await game.connect(playerTwo).joinQueue(3, OTHER_ENTRY_FEE, { value: OTHER_ENTRY_FEE });

      const firstMatch = await game.matches(1);
      const secondMatch = await game.matches(2);
      const buckets = normalizeBuckets(await game.getActiveMatchBuckets());

      expect(buckets).to.deep.equal([
        {
          matchId: "1",
          maxPlayers: 2,
          playerCount: 1,
          entryFee: ENTRY_FEE.toString(),
          deadline: firstMatch.deadline.toString(),
          status: 0,
          players: [playerOne.address],
        },
        {
          matchId: "2",
          maxPlayers: 3,
          playerCount: 1,
          entryFee: OTHER_ENTRY_FEE.toString(),
          deadline: secondMatch.deadline.toString(),
          matchId: "2",
          status: 0,
          players: [playerTwo.address],
        },
      ]);
    });

    it("returns joined player addresses in one call", async function () {
      const { game, playerOne, playerTwo, playerThree } = await deployFixture();

      await game.connect(playerOne).joinQueue(2, ENTRY_FEE, { value: ENTRY_FEE });
      await game.connect(playerTwo).joinQueue(3, OTHER_ENTRY_FEE, { value: OTHER_ENTRY_FEE });
      await game.connect(playerThree).joinQueue(3, OTHER_ENTRY_FEE, { value: OTHER_ENTRY_FEE });

      const firstMatch = await game.matches(1);
      const secondMatch = await game.matches(2);
      const buckets = normalizeBuckets(await game.getActiveMatchBuckets());

      expect(buckets).to.deep.equal([
        {
          matchId: "1",
          maxPlayers: 2,
          playerCount: 1,
          entryFee: ENTRY_FEE.toString(),
          deadline: firstMatch.deadline.toString(),
          status: 0,
          players: [playerOne.address],
        },
        {
          matchId: "2",
          maxPlayers: 3,
          playerCount: 2,
          entryFee: OTHER_ENTRY_FEE.toString(),
          deadline: secondMatch.deadline.toString(),
          status: 0,
          players: [playerTwo.address, playerThree.address],
        },
      ]);
    });

    it("filters out stale pointers when the deadline has passed", async function () {
      const { game, playerOne } = await deployFixture();

      await game.connect(playerOne).joinQueue(2, ENTRY_FEE, { value: ENTRY_FEE });
      await increaseTime(10 * 60 + 1);

      expect(await game.activeMatchByQueueKey(await game.queueKeyOf(2, ENTRY_FEE))).to.equal(1);
      expect(await game.getActiveMatch(2, ENTRY_FEE)).to.equal(0);
      expect(await game.getActiveMatchBuckets()).to.deep.equal([]);
    });

    it("filters out cancelled matches even if the pointer has not been rewritten", async function () {
      const { game, playerOne } = await deployFixture();

      await game.connect(playerOne).joinQueue(2, ENTRY_FEE, { value: ENTRY_FEE });
      await increaseTime(10 * 60 + 1);
      await game.cancelExpiredMatch(1);

      expect(await game.getActiveMatch(2, ENTRY_FEE)).to.equal(0);
      expect(await game.getActiveMatchBuckets()).to.deep.equal([]);
    });

    it("filters out matches that are already full", async function () {
      const { game, playerOne, playerTwo, playerThree } = await deployFixture();

      await game.connect(playerOne).joinQueue(2, ENTRY_FEE, { value: ENTRY_FEE });
      await game.connect(playerTwo).joinQueue(2, ENTRY_FEE, { value: ENTRY_FEE });
      await game.connect(playerThree).joinQueue(3, OTHER_ENTRY_FEE, { value: OTHER_ENTRY_FEE });

      const secondMatch = await game.matches(2);
      const buckets = normalizeBuckets(await game.getActiveMatchBuckets());

      expect(buckets).to.deep.equal([
        {
          matchId: "2",
          maxPlayers: 3,
          playerCount: 1,
          entryFee: OTHER_ENTRY_FEE.toString(),
          deadline: secondMatch.deadline.toString(),
          status: 0,
          players: [playerThree.address],
        },
      ]);
    });

    it("keeps historical known fees enumerable after disabling them", async function () {
      const { game, owner, playerOne } = await deployFixture();

      await game.connect(owner).setAllowedEntryFee(NEW_ENTRY_FEE, true);
      await game.connect(playerOne).joinQueue(2, NEW_ENTRY_FEE, { value: NEW_ENTRY_FEE });
      await game.connect(owner).setAllowedEntryFee(NEW_ENTRY_FEE, false);

      const matchData = await game.matches(1);
      const knownEntryFees = await game.getKnownEntryFees();
      expect(knownEntryFees.filter((fee) => fee.eq(NEW_ENTRY_FEE))).to.have.length(1);

      const buckets = normalizeBuckets(await game.getActiveMatchBuckets());
      expect(buckets).to.deep.equal([
        {
          matchId: "1",
          maxPlayers: 2,
          playerCount: 1,
          entryFee: NEW_ENTRY_FEE.toString(),
          deadline: matchData.deadline.toString(),
          status: 0,
          players: [playerOne.address],
        },
      ]);
      expect(await game.getActiveMatch(2, NEW_ENTRY_FEE)).to.equal(1);
    });
  });
});
