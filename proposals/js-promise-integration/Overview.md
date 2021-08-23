# JavaScript-Promise Integration Proposal

## Summary

The purpose of this proposal is to provide relatively efficient and relatively ergonimic interop between JavaScript promises and WebAssembly but working under the constraint that the only changes are to the JS API and not to core wasm.
The expectation is that the [Stack-Switching proposal](https://github.com/WebAssembly/stack-switching) will eventually extend core WebAssembly with the functionality to implement the operations we provide in this proposal directly within WebAssembly, along with many other valuable stack-switching operations, but that this particular use case for stack switching had sufficient urgency to merit a faster path via just the JS API.
For more information, please refer to the notes and slides for the [June 28, 2021 Stack Subgroup Meeting](https://github.com/WebAssembly/meetings/blob/main/stack/2021/sg-6-28.md), which details the usage scenarios and factors we took into consideration and summarizes the rationale for how we arrived at the following design.

Following feedback that the Stacks Subgroup had received from TC39, this proposal allows *only* WebAssembly stacks to be suspended&mdash;it makes no changes to the JavaScript language and, in particular, does not indirectly enable support for detached `asycn`/`await` in JavaScript.

This proposal depends (loosely) on the [js-types](https://github.com/WebAssembly/js-types/) proposal, which introduces `WebAssembly.Function` as a subclass of `Function`.

## Interface

The proposal is to add the following interface, constructor, and methods to the JS API, with further details on their semantics below.

```
interface Suspender {
   constructor();
   Function suspendOnReturnedPromise(Function func); // import wrapper
   // overloaded: WebAssembly.Function suspendOnReturnedPromise(WebAssembly.Function func);
   WebAssembly.Function returnPromiseOnSuspend(WebAssembly.Function func); // export wrapper
}
```

## Example

The following is an example of how we expect one to use this API.
In our usage scenarios, we found it useful to consider WebAssembly modules to conceputally have "synchronous" and "asynchronous" imports and exports.
The current JS API supports only "synchronous" imports and exports.
The methods of the Suspender interface are used to wrap relevant imports and exports in order to make "asynchronous", with the Suspender object itself explicitly connecting these imports and exports together to facilitate both implementation and composability.

WebAssembly (`demo.wasm`):
```
(module
    (import "js" "init_state" (func $init_state (result f64)))
    (import "js" "compute_delta" (func $compute_delta (result f64)))
    (global $state f64)
    (func $init (global.set $state (call $init_state)))
    (start $init)
    (func $get_state (export "get_state") (result f64) (global.get $state))
    (func $update_state (export "update_state") (result f64)
      (global.set (f64.add (global.get $state) (call $compute_delta)))
      (global.get $state)
    )
)
```

Text (`data.txt`):
```
19827.987
```

JavaScript:
```
var suspender = new Suspender();
var init_state = () => 2.71;
var compute_delta = () => fetch('data.txt').then(res => res.text()).then(txt => parseFloat(txt));
var importObj = {js: {
    init_state: init_state,
    compute_delta: suspender.suspendOnReturnedPromise(compute_delta)
}};

fetch('demo.wasm').then(response =>
    response.arrayBuffer()
).then(buffer =>
    WebAssembly.instantiate(buffer, importObj)
).then(({module, instance}) => {
    var get_state = instance.exports.get_state;
    var update_state = suspender.returnPromiseOnSuspend(instance.exports.update_state);
    ...
});
```

In this example, we have a WebAssembly module that is a very simplistic state machine&mdash;every time you update the state, it simply calls an import to compute a delta to add to the state.
On the JavaScript side, though, the function we want to use for computing the delta turns out to need to be run asynchronously; that is, it returns a Promise of a Number rather than a Number itself.

We can bridge this synchrony gap by using the new JS API.
In the example, an import of the WebAssembly module is wrapped using `suspender.suspendOnReturnedPromise`, and an export is wrapped using `suspender.returnPromiseOnSuspend`, both using the same `suspender`.
That `suspender` connects to the two together.
It makes it so that, if ever the (unwrapped) import returns a Promise, the (wrapped) export returns a Promise, with all the computation in between being "suspended" until the import's Promise resolves.
The wrapping of the export is essentially adding an `async` marker, and the wrapping of the import is essentially adding an `await` marker, but unlike JavaScript we do not have to explicitly thread `async`/`await` all the way through all the intermediate WebAssembly functions!

Meanwhile, the call made to the `init_state` during initialization necessarily returns without suspending, and calls to the export `get_state`  also always returns without suspending, so the proposal still supports the existing "synchronous" imports and exports the WebAssembly ecosystem uses today.
Of course, there are many details being skimmed over, such as the fact that if a synchronous export calls an asynchronous import then the program will trap if the import tries to suspend.
The following provides a more detailed specification as well as some implementation strategy.

## Specification

A `Suspender` is in one of the following states:
* **Inactive** - not being used at the moment
* **Active**[`caller`] - control is inside the `Suspender`, with `caller` being the function that called into the `Suspender` and is expecting an `externref` to be returned
* **Suspended** - currently waiting for some promise to resolve

The method `suspender.returnPromiseOnSuspend(func)` asserts that `func` is a `WebAssembly.Function` with a function type of the form `[ti*] -> [to]` and then returns a `WebAssembly.Function` with function type `[ti*] -> [externref]` that does the following when called with arguments `args`:
1. Traps if `suspender`'s state is not **Inactive**
2. Changes `suspender`'s state to **Active**[`caller`] (where `caller` is the current caller)
3. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
4. Asserts that `suspender`'s state is **Active**[`caller'`] for some `caller'` (should be guaranteed, though the caller might have changed)
5. Changes `suspender`'s state to **Inactive**
6. Returns (or rethrows) `result` to `caller'`

The method `suspender.suspendOnReturnedPromise(func)`
* if `func` is a `WebAssembly.Function`, then asserts that its function type is of the form `[t*] -> [externref]` and returns a `WebAssembly.Function` with function type `[t*] -> [externref]`;
* otherwise, asserts that `func` is a `Function` and returns a `Function`.

In either case, the function returned by `suspender.suspendOnReturnedPromise(func)` does the following when called with arguments `args`:
1. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
2. If `result` is not a returned Promise, then returns (or rethrows) `result`
3. Traps if `suspender`'s state is not **Active**[`caller`] for some `caller`
4. Lets `frames` be the stack frames since `caller`
5. Traps if there are any frames of non-suspendable functions in `frames`
6. Changes `suspender`'s state to **Suspended**
7. Returns the result of `result.then(onFulfilled, onRejected)` with functions `onFulfilled` and `onRejected` that do the following:
   1. Asserts that `suspender`'s state is **Suspended** (should be guaranteed)
   2. Changes `suspender`'s state to **Active**[`caller'`], where `caller'` is the caller of `onFulfilled`/`onRejected`
   3. * In the case of `onFulfilled`, converts the given value to `externref` and returns that to `frames`
      * In the case of `onRejected`, throws the given value up to `frames` as an exception according to the JS API of the [Exception Handling](https://github.com/WebAssembly/exception-handling/) proposal

A function is suspendable if it was
* defined by a WebAssembly module,
* returned by `suspendOnReturnedPromise`,
* returned by `returnPromiseOnSuspend`,
* or generated by [creating a host function](https://webassembly.github.io/spec/js-api/index.html#create-a-host-function) for a suspendable function

Importantly, functions written in JavaScript are *not* suspendable, conforming to feedback from members of [TC39](https://tc39.es/), and host functions (except for the few listed above) are *not* suspendable, conforming to feedback from engine maintainers.

## Implementation

The following is an implementation strategy for this proposal.
It assumes engine support for stack-switching, which of course is where the main implementation challenges lie.

There are two kinds of stacks: a host (and JavaScript) stack, and a WebAssembly stack. Every WebAssembly stack has a suspender field called `suspender`. Every thread has a host stack.

Every `Suspender` has two stack-reference fields: one called `caller` and one called `suspended`.
* In the **Inactive** state, both fields are null.
* In the **Active** state, the `caller` field references the (suspended) stack of the caller, and the `suspended` field is null
* In the **Suspended** state, the `suspended` field references the (suspended) WebAssembly stack currently associated with the suspender, and the `caller` field is null.

`suspender.returnPromiseOnSuspend(func)(args)` is implemented by
1. Checking that `suspender.caller` and `suspended.suspended` are null (trapping otherwise)
2. Letting `stack` be a newly allocated WebAssembly stack associated with `suspender`
3. Switching to `stack` and storing the former stack in `suspender.caller`
4. Letting `result` be the result of `func(args)` (or any trap or thrown exception)
5. Switching to `suspender.caller` and setting it to null
6. Freeing `stack`
7. Returning (or rethrowing) `result`

`suspender.suspendOnReturnedPromise(func)(args)` is implemented by
1. Calling `func(args)`, catching any trap or thrown exception
2. If `result` is not a returned Promise, returning (or rethrowing) `result`
3. Checking that `suspender.caller` is not null (trapping otherwise)
4. Let `stack` be the current stack
5. While `stack` is not a WebAssembly stack associated with `suspender`:
   * Checking that `stack` is a WebAssembly stack (trapping otherwise)
   * Updating `stack` to be `stack.suspender.caller`
6. Switching to `suspender.caller`, setting it to null, and storing the former stack in `suspender.suspended`
7. Returning the result of `result.then(onFulfilled, onRejected)` with functions `onFulfilled` and `onRejected` that are implemented by
   1. Switching to `suspender.suspended`, setting it to null, and storing the former stack in `suspender.caller`
   2. * In the case of `onFulfilled`, converting the given value to `externref` and returning it
      * In the case of `onRejected`, rethrowing the given value

The implementation of the function generated by [creating a host function](https://webassembly.github.io/spec/js-api/index.html#create-a-host-function) for a suspendable function is changed to first switch to the host stack of the current thread (if not already on it) and to lastly switch back to the former stack.
