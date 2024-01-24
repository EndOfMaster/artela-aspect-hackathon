
import {
    allocate,
    entryPoint,
    execute,
    IPostContractCallJP,
    PostContractCallInput,
    PreTxExecuteInput,
    IPreTxExecuteJP,
    PreContractCallInput,
    IPreContractCallJP
} from "@artela/aspect-libs";

/**
 * Please describe what functionality this aspect needs to implement.
 *
 * About the concept of Aspect @see [join-point](https://docs.artela.network/develop/core-concepts/join-point)
 * How to develop an Aspect  @see [Aspect Structure](https://docs.artela.network/develop/reference/aspect-lib/aspect-structure)
 */
class Aspect implements IPostContractCallJP, IPreTxExecuteJP, IPreContractCallJP {

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
     * preTxExecute is a join-point that gets invoked before the execution of a transaction.
     * This method is optional; remove IPreTxExecuteJP if you do not want to include this functionality.
     * 执行前来查看块数据
     * @param input Input of the given join-point
     * @return void
     */
    preTxExecute(input: PreTxExecuteInput): void {
    }

    /**
     * preContractCall is a join-point that gets invoked before the execution of a contract call.
     * 获取进入合约数据
     * @param input Input of the given join-point
     * @return void
     */
    preContractCall(input: PreContractCallInput): void {

    }

    /**
     * postContractCall is a join-point which will be invoked after a contract call has finished.
     * 执行完用来check
     * @param input input to the current join point
     */
    postContractCall(input: PostContractCallInput): void {
        // Implement me...
    }
}

// 2.register aspect Instance
const aspect = new Aspect()
entryPoint.setAspect(aspect)

// 3.must export it
export { execute, allocate }

