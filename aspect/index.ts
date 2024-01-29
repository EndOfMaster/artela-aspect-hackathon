
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
} from "@artela/aspect-libs";
import { Protobuf } from 'as-proto/assembly';

const createSig = "9f7b4579";
const earnedSig = "008cc262";
const extendSig = "9714378c";
const exitSig = "e9fad8ee";
const getRewardSig = "3d18b912";
const proExtendSig = "ab8088e2";
const refillSig = "ca9d07ba";
const refreshSig = "754ecc26";

const needUpdateRewardFuncs = [createSig, earnedSig, extendSig, exitSig, getRewardSig, proExtendSig, refillSig, refreshSig]

// 1 weeks
const MIN_STEP: BigInt = BigInt.from(60).mul(60).mul(24).mul(7);

const BASE: BigInt = BigInt.from(10).pow(18);

/**
 * Please describe what functionality this aspect needs to implement.
 *
 * About the concept of Aspect @see [join-point](https://docs.artela.network/develop/core-concepts/join-point)
 * How to develop an Aspect  @see [Aspect Structure](https://docs.artela.network/develop/reference/aspect-lib/aspect-structure)
 */
class Aspect implements IPostContractCallJP, IPreContractCallJP {

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

    /**
     * preContractCall is a join-point that gets invoked before the execution of a contract call.
     * 结算每个节点的利息
     * @param input Input of the given join-point
     * @return void
     */
    preContractCall(input: PreContractCallInput): void {
        let selector = ethereum.parseMethodSig(input.call!.data);

        // 检查function是否需要settle
        if (needUpdateRewardFuncs.includes(selector)) {

            //拿到每个参数
            const _lastUpdateTime = sys.aspect.mutableState.get<BigInt>("lastUpdateTime");
            let lastUpdateTime = _lastUpdateTime.unwrap();

            const _lastSettledTime = sys.aspect.mutableState.get<BigInt>("lastSettledTime");
            let lastSettledTime = _lastSettledTime.unwrap();

            const _accSettledBalance = sys.aspect.mutableState.get<BigInt>("accSettledBalance");
            let accSettledBalance = _accSettledBalance.unwrap();

            const _rewardPerToken = sys.aspect.mutableState.get<BigInt>("rewardPerToken");
            let rewardPerToken = _rewardPerToken.unwrap();

            let rewardRate = sys.aspect.mutableState.get<BigInt>("rewardRate").unwrap();
            let totalSupply = sys.aspect.mutableState.get<BigInt>("totalSupply").unwrap();

            const _now = sys.hostApi.runtimeContext.get("block.header.timestamp");
            const now = BigInt.from(Protobuf.decode<UintData>(_now, UintData.decode).data.toString());

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
                    lastSettledTime = MIN_STEP.sub(now.sub(lastSettledTime).mod(MIN_STEP)).add(_now);
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


            //2. Update the reward of specific users

            const dueTime = sys.aspect.mutableState.get<BigInt>("{dueTimes}_{" + input.call!.from + "}").unwrap();
            const _userRewardPerTokenPaid = sys.aspect.mutableState.get<BigInt>("{userRewardPerTokenPaid}_{" + input.call!.from + "}");

            if (dueTime.gt(0)) {
                //If the user's lock expires, retrieve the rewardpertokenstored of the expired node
                if (dueTime.lt(now)) {
                    const _node = sys.aspect.mutableState.get<string>("{nodes}_{" + lastSettledTime + "}");
                    const nodeStr = _node.unwrap().split(",")

                    let nodeRewardPerTokenSettled = BigInt.from(nodeStr[0]);
                    rewardPerToken = nodeRewardPerTokenSettled;
                }
                const veBalance = sys.aspect.mutableState.get<BigInt>("{balances}_{" + input.call!.from + "}").unwrap();
                let userRewardPerTokenPaid = _userRewardPerTokenPaid.unwrap();

                const _reward = sys.aspect.mutableState.get<BigInt>("{rewards}_{" + input.call!.from + "}");
                let reward = _reward.unwrap();

                reward = veBalance.mul(rewardPerToken.sub(userRewardPerTokenPaid)).div(BASE).add(reward);
                _reward.set<BigInt>(reward);
                _reward.reload()
            }

            _userRewardPerTokenPaid.set<BigInt>(rewardPerToken);
        }
    }

    /**
     * postContractCall is a join-point which will be invoked after a contract call has finished.
     * 执行完用来check
     * @param input input to the current join point
     */
    postContractCall(input: PostContractCallInput): void {
        const selector = ethereum.parseMethodSig(input.call!.data);

        // create locker
        if (selector === createSig) {
            const _params = sys.aspect.transientStorage.get<string>('context').unwrap();
            const params = _params.split(",");
            const dueTime = params[0];
            const veAAHAmount = params[1];

            const _totalSupply = sys.aspect.mutableState.get<BigInt>("totalSupply");
            let totalSupply = _totalSupply.unwrap()
            _totalSupply.set<BigInt>(totalSupply.add(veAAHAmount))
            _totalSupply.reload();

            const _balance = sys.aspect.mutableState.get<BigInt>("{balances}_{" + input.call!.from + "}")
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

        

    }
}

// 2.register aspect Instance
const aspect = new Aspect()
entryPoint.setAspect(aspect)

// 3.must export it
export { execute, allocate }

