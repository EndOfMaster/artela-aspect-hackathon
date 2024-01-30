
import {
    allocate,
    entryPoint,
    execute,
    IPostContractCallJP,
    PostContractCallInput,
    PreContractCallInput,
    IPreContractCallJP,
    ethereum,
    sys,
    BigInt,
    UintData,
    uint8ArrayToHex,
    IAspectOperation,
    OperationInput,
} from "@artela/aspect-libs";
import { Protobuf } from 'as-proto/assembly';

const createSig = "9f7b4579";
const earnedSig = "008cc262";
const extendSig = "9714378c";
const exitSig = "e9fad8ee";
const getRewardSig = "3d18b912";
const refillSig = "ca9d07ba";
const refreshSig = "754ecc26";
const estimateLockerAPYSig = "3cdafd19"
const getLockersInfoSig = "25c2aaa0"

const startTime = BigInt.from(1709222400);
const rewardRate = BigInt.from('158984533984533985')

const needSettleFuncs = [createSig, refillSig, extendSig, refreshSig, getRewardSig, exitSig, earnedSig, estimateLockerAPYSig, getLockersInfoSig]

const needUpdateUserRewardFuncs = [createSig, refillSig, extendSig, refreshSig, getRewardSig, exitSig, earnedSig, estimateLockerAPYSig]

// 1 weeks
const MIN_STEP: BigInt = BigInt.from(60).mul(60).mul(24).mul(7);

const BASE: BigInt = BigInt.from(10).pow(18);

/**
 * Please describe what functionality this aspect needs to implement.
 *
 * About the concept of Aspect @see [join-point](https://docs.artela.network/develop/core-concepts/join-point)
 * How to develop an Aspect  @see [Aspect Structure](https://docs.artela.network/develop/reference/aspect-lib/aspect-structure)
 */
class Aspect implements IPostContractCallJP, IPreContractCallJP, IAspectOperation {

    /**
     * isOwner is the governance account implemented by the Aspect, when any of the governance operation
     * (including upgrade, config, destroy) is made, isOwner method will be invoked to check
     * against the initiator's account to make sure it has the permission.
     *
     * @param sender address of the transaction
     * @return true if check success, false if check fail
     */
    isOwner(sender: Uint8Array): bool {
        return true;
    }

    settle(now: BigInt, selector: string): void {
        const _rewardPerToken = sys.aspect.mutableState.get<BigInt>("rewardPerToken");
        let rewardPerToken = _rewardPerToken.unwrap();

        const _lastSettledTime = sys.aspect.mutableState.get<BigInt>("lastSettledTime");
        let lastSettledTime = _lastSettledTime.unwrap();
        if (lastSettledTime.eq(0)) {
            lastSettledTime = startTime;
        }

        const _lastUpdateTime = sys.aspect.mutableState.get<BigInt>("lastUpdateTime");
        let lastUpdateTime = _lastUpdateTime.unwrap();
        if (lastUpdateTime.eq(0)) {
            lastUpdateTime = startTime;
        }

        // 检查function是否需要settle
        if (needSettleFuncs.includes(selector)) {

            const _accSettledBalance = sys.aspect.mutableState.get<BigInt>("accSettledBalance");
            let accSettledBalance = _accSettledBalance.unwrap();

            let totalSupply = sys.aspect.mutableState.get<BigInt>("totalSupply").unwrap();

            //1. Update the expired lock of the history node and calculate the `rewardPerToken` at that time

            while (lastSettledTime.lt(now)) {

                const _node = sys.aspect.mutableState.get<string>("{nodes}_{" + lastSettledTime + "}");
                const nodeStr = _node.unwrap().split(",")

                let nodeRewardPerTokenSettled = BigInt.from(nodeStr[0]);
                const nodeBalance = BigInt.from(nodeStr[1]);

                if (nodeBalance.gt(0)) {
                    rewardPerToken = rewardPerToken.add(lastSettledTime.sub(lastUpdateTime).mul(rewardRate).mul(BASE).div(totalSupply.sub(accSettledBalance)));

                    //After the rewardpertoken is settled, add the balance of this node to accsettledbalance
                    accSettledBalance = accSettledBalance.add(nodeBalance);

                    //Record node settlement results
                    nodeRewardPerTokenSettled = rewardPerToken;
                    _node.set<string>(nodeRewardPerTokenSettled + "," + nodeBalance);
                    _node.reload();

                    //The first settlement is the time from the last operation to the first one behind it,
                    //and then updated to the next node time
                    lastUpdateTime = lastSettledTime;
                }

                //If accsettledbalance and totalsupply are equal,
                //it is equivalent to all lock positions expire.
                if (accSettledBalance.eq(totalSupply)) {
                    //At this time, update lastsettledtime, and then jump out of the loop
                    lastSettledTime = MIN_STEP.sub(now.sub(lastSettledTime).mod(MIN_STEP)).add(now);
                    break;
                }

                //Update to next node time
                lastSettledTime = lastSettledTime.add(MIN_STEP);
            }
            _accSettledBalance.set<BigInt>(accSettledBalance);
            _accSettledBalance.reload()

            _lastSettledTime.set<BigInt>(lastSettledTime);
            _lastSettledTime.reload()

            rewardPerToken = totalSupply == accSettledBalance ? rewardPerToken :
                rewardPerToken.add(now.sub(lastUpdateTime).mul(rewardRate).mul(BASE).div(totalSupply.sub(accSettledBalance)));

            _rewardPerToken.set<BigInt>(rewardPerToken);
            _rewardPerToken.reload();

            _lastUpdateTime.set<BigInt>(now);
            _lastUpdateTime.reload();
        }
    }

    updateReward(now: BigInt, selector: string, sender: string) {
        const _rewardPerToken = sys.aspect.mutableState.get<BigInt>("rewardPerToken");
        let rewardPerToken = _rewardPerToken.unwrap();

        const _lastSettledTime = sys.aspect.mutableState.get<BigInt>("lastSettledTime");
        let lastSettledTime = _lastSettledTime.unwrap();

        //2. Update the reward of specific users
        if (needUpdateUserRewardFuncs.includes(selector)) {
            const dueTime = sys.aspect.mutableState.get<BigInt>("{dueTimes}_{" + sender + "}").unwrap();
            const _userRewardPerTokenPaid = sys.aspect.mutableState.get<BigInt>("{userRewardPerTokenPaid}_{" + sender + "}");

            if (dueTime.gt(0)) {
                //If the user's lock expires, retrieve the rewardpertokenstored of the expired node
                if (dueTime.lt(now)) {
                    const _node = sys.aspect.mutableState.get<string>("{nodes}_{" + lastSettledTime + "}");
                    const nodeStr = _node.unwrap().split(",")

                    let nodeRewardPerTokenSettled = BigInt.from(nodeStr[0]);
                    rewardPerToken = nodeRewardPerTokenSettled;
                }
                const veBalance = sys.aspect.mutableState.get<BigInt>("{balances}_{" + sender + "}").unwrap();
                let userRewardPerTokenPaid = _userRewardPerTokenPaid.unwrap();

                const _reward = sys.aspect.mutableState.get<BigInt>("{rewards}_{" + sender + "}");
                let reward = _reward.unwrap();

                reward = veBalance.mul(rewardPerToken.sub(userRewardPerTokenPaid)).div(BASE).add(reward);
                _reward.set<BigInt>(reward);
                _reward.reload()
            }

            _userRewardPerTokenPaid.set<BigInt>(rewardPerToken);
        }
    }

    //function earned(address)
    operation(input: OperationInput): Uint8Array {
        const _now = sys.hostApi.runtimeContext.get("block.header.timestamp");
        const now = BigInt.from(Protobuf.decode<UintData>(_now, UintData.decode).data.toString());

        const address = uint8ArrayToHex(input.callData);

        this.settle(now, earnedSig);
        this.updateReward(now, earnedSig, address);

        const reward = sys.aspect.mutableState.get<BigInt>("{rewards}_{" + address + "}").unwrap();
        return reward.toUint8Array();
    }

    /**
     * preContractCall is a join-point that gets invoked before the execution of a contract call.
     * @param input Input of the given join-point
     * @return void
     */
    preContractCall(input: PreContractCallInput): void {
        let selector = ethereum.parseMethodSig(input.call!.data);
        const _now = sys.hostApi.runtimeContext.get("block.header.timestamp");
        const now = BigInt.from(Protobuf.decode<UintData>(_now, UintData.decode).data.toString());

        let sender = uint8ArrayToHex(input.call!.from);

        if (selector === estimateLockerAPYSig || selector === earnedSig) {
            sender = uint8ArrayToHex(input.call!.data);
        }

        this.settle(now, selector);
        this.updateReward(now, selector, sender);

        if (selector === getRewardSig) {
            const reward = sys.aspect.mutableState.get<BigInt>("{rewards}_{" + sender + "}").unwrap();
            const _reward = sys.aspect.transientStorage.get<BigInt>('reward');
            _reward.set<BigInt>(reward);
        }

        if (selector === estimateLockerAPYSig || selector === getLockersInfoSig) {
            const accSettledBalance = sys.aspect.mutableState.get<BigInt>("accSettledBalance").unwrap();
            const context0 = sys.aspect.transientStorage.get<BigInt>('accSettledBalance')
            context0.set<BigInt>(accSettledBalance);

            const context1 = sys.aspect.transientStorage.get<BigInt>('rewardRate')
            context1.set<BigInt>(rewardRate);
        }
    }

    /**
     * postContractCall is a join-point which will be invoked after a contract call has finished.
     * @param input input to the current join point
     */
    postContractCall(input: PostContractCallInput): void {
        const selector = ethereum.parseMethodSig(input.call!.data);

        // create locker or increased locked staked sAAH and harvest veAAH
        if (selector === createSig || selector === refillSig) {
            const _params = sys.aspect.transientStorage.get<string>('context').unwrap();
            const params = _params.split(",");
            const dueTime = params[0];
            const veAAHAmount = params[1];

            const _totalSupply = sys.aspect.mutableState.get<BigInt>("totalSupply");
            let totalSupply = _totalSupply.unwrap()
            _totalSupply.set<BigInt>(totalSupply.add(veAAHAmount))
            _totalSupply.reload();

            const _balance = sys.aspect.mutableState.get<BigInt>("{balances}_{" + uint8ArrayToHex(input.call!.from) + "}")
            let balance = _balance.unwrap();
            _balance.set<BigInt>(balance.add(veAAHAmount));
            _balance.reload()

            const _node = sys.aspect.mutableState.get<string>("{nodes}_{" + dueTime + "}");
            const nodeStr = _node.unwrap().split(",")

            const nodeRewardPerTokenSettled = nodeStr[0];
            const nodeBalance = BigInt.from(nodeStr[1]);

            _node.set<string>(nodeRewardPerTokenSettled + "," + nodeBalance.add(veAAHAmount));
            _node.reload();
        }

        //Increase the lock duration and harvest veAAH.
        if (selector === extendSig) {
            const _params = sys.aspect.transientStorage.get<string>('context').unwrap();
            const params = _params.split(",");
            const dueTime = params[0];
            const veAAHAmount = params[1];
            const oldDueTime = params[2];

            const _balance = sys.aspect.mutableState.get<BigInt>("{balances}_{" + uint8ArrayToHex(input.call!.from) + "}")
            let oldBalance = _balance.unwrap();
            _balance.set<BigInt>(oldBalance.add(veAAHAmount));
            _balance.reload();

            //Subtract the user balance of the original node
            const _node0 = sys.aspect.mutableState.get<string>("{nodes}_{" + oldDueTime + "}");
            const nodeStr0 = _node0.unwrap().split(",")
            const nodeRewardPerTokenSettled0 = nodeStr0[0];
            const nodeBalance0 = BigInt.from(nodeStr0[1]);
            _node0.set<string>(nodeRewardPerTokenSettled0 + "," + nodeBalance0.sub(oldBalance));
            _node0.reload();

            const _totalSupply = sys.aspect.mutableState.get<BigInt>("totalSupply");
            let totalSupply = _totalSupply.unwrap()
            _totalSupply.set<BigInt>(totalSupply.add(veAAHAmount))
            _totalSupply.reload();

            //Add the user balance of the original node to the new node
            const _node1 = sys.aspect.mutableState.get<string>("{nodes}_{" + dueTime + "}");
            const nodeStr1 = _node1.unwrap().split(",")
            const nodeRewardPerTokenSettled1 = nodeStr1[0];
            const nodeBalance1 = BigInt.from(nodeStr1[0]);
            _node1.set<string>(nodeRewardPerTokenSettled1 + "," + nodeBalance1.add(veAAHAmount).add(oldBalance));
            _node1.reload();
        }

        //Lock Staked sAAH and and update veAAH balance.
        if (selector === refreshSig) {
            const _params = sys.aspect.transientStorage.get<string>('context').unwrap();
            const params = _params.split(",");
            const dueTime = params[0];
            const veAAHAmount = BigInt.from(params[1]);

            const _balance = sys.aspect.mutableState.get<BigInt>("{balances}_{" + uint8ArrayToHex(input.call!.from) + "}")
            let oldBalance = _balance.unwrap();

            _balance.set<BigInt>(veAAHAmount);
            _balance.reload();

            const rewardPerToken = sys.aspect.mutableState.get<BigInt>("rewardPerToken").unwrap();

            const _userRewardPerTokenPaid = sys.aspect.mutableState.get<BigInt>("{userRewardPerTokenPaid}_{" + uint8ArrayToHex(input.call!.from) + "}");
            _userRewardPerTokenPaid.set<BigInt>(rewardPerToken);
            _userRewardPerTokenPaid.reload();

            const _totalSupply = sys.aspect.mutableState.get<BigInt>("totalSupply");
            const totalSupply = _totalSupply.unwrap()
            _totalSupply.set<BigInt>(totalSupply.add(veAAHAmount).sub(oldBalance));
            _totalSupply.reload();

            const _node = sys.aspect.mutableState.get<string>("{nodes}_{" + dueTime + "}");
            const nodeStr = _node.unwrap().split(",")
            const nodeRewardPerTokenSettled = nodeStr[0];
            const nodeBalance = BigInt.from(nodeStr[1]);
            _node.set<string>(nodeRewardPerTokenSettled + "," + nodeBalance.add(veAAHAmount));
            _node.reload();

            const _accSettledBalance = sys.aspect.mutableState.get<BigInt>("accSettledBalance");
            const accSettledBalance = _accSettledBalance.unwrap();
            _accSettledBalance.set<BigInt>(accSettledBalance.sub(oldBalance));
            _accSettledBalance.reload();
        }

        if (selector === getRewardSig) {
            const _reward = sys.aspect.mutableState.get<BigInt>("{rewards}_{" + uint8ArrayToHex(input.call!.from) + "}");
            _reward.set<BigInt>(BigInt.from(0));
            _reward.reload();
        }

        if (selector === exitSig) {
            //getReward part
            const _reward = sys.aspect.mutableState.get<BigInt>("{rewards}_{" + uint8ArrayToHex(input.call!.from) + "}");
            _reward.set<BigInt>(BigInt.from(0));
            _reward.reload();

            //withdraw part
            const _balance = sys.aspect.mutableState.get<BigInt>("{balances}_{" + uint8ArrayToHex(input.call!.from) + "}")
            let oldBalance = _balance.unwrap();
            _balance.set<BigInt>(BigInt.from(0));
            _balance.reload();

            const _totalSupply = sys.aspect.mutableState.get<BigInt>("totalSupply");
            const totalSupply = _totalSupply.unwrap()
            _totalSupply.set<BigInt>(totalSupply.sub(oldBalance));
            _totalSupply.reload();

            const _accSettledBalance = sys.aspect.mutableState.get<BigInt>("accSettledBalance");
            const accSettledBalance = _accSettledBalance.unwrap();
            _accSettledBalance.set<BigInt>(accSettledBalance.sub(oldBalance));
            _accSettledBalance.reload();
        }

    }

}

// 2.register aspect Instance
const aspect = new Aspect()
entryPoint.setAspect(aspect)
entryPoint.setOperationAspect(aspect);

// 3.must export it
export { execute, allocate }

