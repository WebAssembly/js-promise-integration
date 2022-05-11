# JavaScript-Promise Integration Proposal

## Summary

The purpose of this proposal is to provide relatively efficient and relatively ergonimic interop between JavaScript promises and WebAssembly but working under the constraint that the only changes are to the JS API and not to core wasm.
The expectation is that the [Stack-Switching proposal](https://github.com/WebAssembly/stack-switching) will eventually extend core WebAssembly with the functionality to implement the operations we provide in this proposal directly within WebAssembly, along with many other valuable stack-switching operations, but that this particular use case for stack switching had sufficient urgency to merit a faster path via just the JS API.
For more information, please refer to the notes and slides for the [June 28, 2021 Stack Subgroup Meeting](https://github.com/WebAssembly/meetings/blob/main/stack/2021/sg-6-28.md), which details the usage scenarios and factors we took into consideration and summarizes the rationale for how we arrived at the following design.

Following feedback that the Stacks Subgroup had received from TC39, this proposal allows *only* WebAssembly stacks to be suspended&mdash;it makes no changes to the JavaScript language and, in particular, does not indirectly enable support for detached `async`/`await` in JavaScript.

This proposal depends (loosely) on the [js-types](https://github.com/WebAssembly/js-types/) proposal, which introduces `WebAssembly.Function` as a subclass of `Function`.

## Interface

The proposal is to add the following interface, constructor, and methods to the JS API, with further details on their semantics below.

```
[Exposed=(Window,Worker)]
partial namespace WebAssembly {
  WebAssembly.Function suspendOnReturnedPromise(Suspender suspender,Function func);
  Function returnPromiseOnSuspend(Suspender suspender, WebAssembly.Function func);
}

[LegacyNamespace=WebAssembly, Exposed=(Window,Worker)]
interface Suspender {
   constructor();
   WebAssembly.Function suspendOnReturnedPromise(Function func);
   Function returnPromiseOnSuspend(WebAssembly.Function func);
}
```

The core concept embodied here is that an exported function and any imported function that is called eventaully from that exported function form a bracketed pair. 

In order to accomodate asynchronous external functions (aka `Promise` returning functions) any `Promise` value returned by the import is immediately propagated out through the export. Any pending computation is suspended and 'packaged up' in the returned `Promise`. This pending computation will be resumed when the `Promise` is fulfilled.

The bracketing of the exports and the imports is achieved using a combination of function wrappers and shared `Suspender` objects. 

## Example

There are two expected patterns of use: where a single `Suspender` statically connects exports to imports; and where the connection is established dynamically. Since it is simpler, we will give an example of the first approach here.

It is useful to consider WebAssembly modules to conceputally have "synchronous" and "asynchronous" imports and exports. A primary goal for this API is to enable WebAssembly modules that expect synchronous imports to be connected to implementations that are asynchronous. We achieve this by wrapping both the exports and the imports with functions that mediate between the two worlds. Wrapped exports and imports are connected with a shared `Suspender` object to facilitate both implementation and composability.

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

In this example, we have a WebAssembly module that is a very simple state machine—driven from JavaScript. Whenever the JavaScript client code wishes to update the state, it invokes the exported `update_state` function. In turn, the WebAssembly `update_state` function calls an import, `compute_delta`, to compute a delta to add to the state.

On the JavaScript side, though, the function we want to use for computing the delta turns out to need to be run asynchronously; that is, it returns a `Promise` of a `Number` rather than a `Number` itself.

We can bridge this synchrony gap by bracketing the exported `update_state` function and the imported `compute_delta` function using a common `suspender` and wrapping the functions.

The `suspender.returnPromiseOnSuspend` function takes a function as argument—in this case `update_state`—and wraps it into a new function, which will be the function actually used by JavaScript code. The new function invokes the wrapped function, i.e. calls it with the same arguments and returns the same results. The difference shows up if the inner function ever suspends.

The `suspender.suspendOnReturnedPromise` function also takes a function as argument: `compute_delta`—the original imported function. When it is called, the wrapper calls `compute_delta` and inspects the returned result. If that result is a `Promise` then, instead of returning that `Promise` to the WebAssembly module, the wrapper suspends `suspender`'s WebAssembly computation instead.

The result is that the `Promise` returned by the `compute_delta` is propagated out immediately to the export and the updated version returned by `update_state`. The update here refers to the capture of the suspended computation.

At some point, the original `Promise` created by `compute_delta` will be resolved – when the file `data.txt` has been loaded and parsed. At that point, the suspended computation will be resumed with the value read from the file.

It is important to note that the WebAssembly program itself is not aware of having been suspended. From the perspective of the `update_state` function itself, it called an import, got the result and carried on. There has been no change to the WebAssembly code during this process.

Similarly, we are not changing the normal flow of the JavaScript code: it is not suspended except in the normally expected ways – due to the `Promise` returned by `compute_delta`.

Bracketing the exports and imports like this is strongly analagous to adding an `async` marker to the export, and the wrapping of the import is essentially adding an `await` marker, but unlike JavaScript we do not have to explicitly thread `async`/`await` all the way through all the intermediate WebAssembly functions!

Notice that we did not wrap the `init_state` import, nor did we wrap the exported `get_state` function. These functions will continue to behave as they would normally: `init_state` will return with whatever value the JavaScript code gives it – `2.71` in our case – and `get_state` can be used by any JavaScript code to get the current state.

This example uses a shared `Suspender` object that is fixed before the WebAssembly module itself is created. This is simple to use; but has some disadvantages. The primary limitation is that, because the `Suspender` is fixed, it is not possible to support any form of reentrancy of the WebAssembly module; other than that we have just seen with non-wrapped exports and imports. 

Instead of associating exports and imports with a `Suspender` object the is fixed at instantiation time, we can parameterize the wrapped exports & imports with a `Suspender` – in addition to any other arguments they would have. This involves using the static versions of the `returnPromiseOnSuspend` and  `suspendOnReturnedPromise` functions.

When a wrapped export is invoked it is given the Suspender to use for that invocation. That Suspender is also used when invoking the wrapped import function. This involves communicating the Suspender object received by the export function into the appropriate imports that that export invokes. This is typically more difficult to achieve without good tooling support when generating the WebAssembly module.

Of course, there are many details being skimmed over, such as the fact that if a synchronous export calls an asynchronous import then the program will trap if the import tries to suspend.
The following provides a more detailed specification as well as some implementation strategy.

## Specification

A `Suspender` is in one of the following states:
* **Inactive** - not being used at the moment
* **Active**[`caller`] - control is inside the `Suspender`, with `caller` being the function that called into the `Suspender` and is expecting an `externref` to be returned
* **Suspended** - currently waiting for some promise to resolve

We separate the specifications of the `Suspender` interface and the static `suspendOnPromise` and `returnPromiseOnSuspend` functions.

The method `suspender.returnPromiseOnSuspend(func)` asserts that `func` is a `WebAssembly.Function` with a function type of the form `[ti*] -> [to]` and then returns a `Function` with implicit function type `[ti*] -> [externref]` that does the following when called with arguments `args`:

1. Traps if `suspender`'s state is not **Inactive**
2. Changes `suspender`'s state to **Active**[`caller`] (where `caller` is the current caller)
3. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
4. Asserts that `suspender`'s state is **Active**[`caller'`] for some `caller'` (should be guaranteed, though the caller might have changed)
5. Changes `suspender`'s state to **Inactive**
6. Returns (or rethrows) `result` to `caller'`

Note that the `returnPromiseOnSuspend` method takes a `WebAssembly.Function` as argument, yet returns a `Function` value. This reflects the constraint that this API may only be used to integrate WebAssembly computations within a JavaScript environment. If the argument is not a `WebAssembly.Function`, or if that entity does not actually contain a WebAssembly function, then a `TypeError` exception is thrown.

The method `suspender.suspendOnReturnedPromise(func)` asserts that `func` is a `Function` object with a function type of the form `[t*] -> [externref]` and returns a `WebAssembly.Function` with function type `[t*] -> [externref]` which does the following when called with arguments `args`:

1. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
2. If `result` is not a returned `Promise`, then returns (or rethrows) `result`
3. Traps if `suspender`'s state is not **Active**[`caller`] for some `caller`
4. Lets `frames` be the stack frames since `caller`
5. Traps if there are any frames of non-suspendable functions in `frames`
6. Changes `suspender`'s state to **Suspended**
7. Returns the result of `result.then(onFulfilled, onRejected)` with functions `onFulfilled` and `onRejected` that do the following:
   1. Asserts that `suspender`'s state is **Suspended** (should be guaranteed)
   2. Changes `suspender`'s state to **Active**[`caller'`], where `caller'` is the caller of `onFulfilled`/`onRejected`
   3. * In the case of `onFulfilled`, converts the given value to `externref` and returns that to `frames`
      * In the case of `onRejected`, throws the given value up to `frames` as an exception according to the JS API of the [Exception Handling](https://github.com/WebAssembly/exception-handling/) proposal

The static function `returnPromiseOnSuspend(func)` asserts that `func` is a `WebAssembly.Function` with a function type of the form `[ti*] -> [to]` and then returns a `Function` with implicit function type `[externref ti*] -> [externref]` that does the following when called with arguments `suspender` followed by `args`:

1. Traps if `suspender`'s state is not **Inactive**
2. Changes `suspender`'s state to **Active**[`caller`] (where `caller` is the current caller)
3. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
4. Asserts that `suspender`'s state is **Active**[`caller'`] for some `caller'` (should be guaranteed, though the caller might have changed)
5. Changes `suspender`'s state to **Inactive**
6. Returns (or rethrows) `result` to `caller'`

The static function `suspendOnReturnedPromise(func)` asserts that `func` is a `Function` object with implicit type of the form `[t*] -> [externref]` and returns a `WebAssembly.Function` with function type `[externref t*] -> [externref]` that does the following when called with arguments `suspender` followed by `args`:

1. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
2. If `result` is not a returned `Promise`, then returns (or rethrows) `result`
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