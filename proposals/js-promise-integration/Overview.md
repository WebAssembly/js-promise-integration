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
[Exposed=(Window,Worker,Worklet)]
partial namespace WebAssembly {
  WebAssembly.Function suspendOnReturnedPromise(WebAssembly.Function func);
  WebAssembly.Function returnPromiseOnSuspend(WebAssembly.Function func);
}

[LegacyNamespace=WebAssembly, Exposed=(Window,Worker,Worklet)]
interface Suspender {
   constructor();
   WebAssembly.Function suspendOnReturnedPromise(WebAssembly.Function func);
   WebAssembly.Function returnPromiseOnSuspend(WebAssembly.Function func);
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
    compute_delta: suspender.suspendOnReturnedPromise(
        new WebAssembly.Function({parameters:[],results:['externref']},compute_delta))
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

The `suspender.returnPromiseOnSuspend` function takes a WebAssembly function as argument—in this case `update_state`—and wraps it into a new WebAssembly function, which will be the function actually used by JavaScript code. The new function invokes the wrapped function, i.e. calls it with the same arguments and returns the same results. The difference shows up if the inner function ever suspends.

The `suspender.suspendOnReturnedPromise` function also takes a WebAssembly function as argument: `compute_delta`—the original imported function. When it is called, the wrapper calls `compute_delta` and inspects the returned result. If that result is a `Promise` then, instead of returning that `Promise` to the WebAssembly module, the wrapper suspends `suspender`'s WebAssembly computation instead.

The result is that the `Promise` returned by the `compute_delta` is propagated out immediately to the export and the updated version returned by `update_state`. The update here refers to the capture of the suspended computation.

At some point, the original `Promise` created by `compute_delta` will be resolved, i.e. when the file `data.txt` has been loaded and parsed. At that point, the suspended computation will be resumed with the value read from the file.

It is important to note that the WebAssembly program itself is not aware of having been suspended. From the perspective of the `update_state` function itself, it called an import, got the result and carried on. There has been no change to the WebAssembly code during this process.

Similarly, we are not changing the normal flow of the JavaScript code: it is not suspended except in the normally expected ways, e.g. the `Promise` returned by `compute_delta`.

Bracketing the exports and imports like this is strongly analagous to adding an `async` marker to the export, and the wrapping of the import is essentially adding an `await` marker, but unlike JavaScript we do not have to explicitly thread `async`/`await` all the way through all the intermediate WebAssembly functions!

Notice that we did not wrap the `init_state` import, nor did we wrap the exported `get_state` function. These functions will continue to behave as they would normally: `init_state` will return with whatever value the JavaScript code gives it—`2.71` in our case—and `get_state` can be used by any JavaScript code to get the current state.

This example uses a shared `Suspender` object that is fixed before the WebAssembly module itself is created. This is simple to use; but has some disadvantages. The primary limitation is that, because the `Suspender` is fixed, it is not possible to support any form of reentrancy of the WebAssembly module, other than what we have just seen with non-wrapped exports and imports. In particular, only one computation can be "inside" a given `Suspender` at a time—whether suspended or active—which means this approach cannot support multiple concurrent computations within the wrapped WebAssembly exports.

Instead of associating exports and imports with a `Suspender` object that is fixed at instantiation time, one can parameterize the wrapped exports & imports with a `Suspender`, in addition to any other arguments they would normally have. This involves using the static versions of the `returnPromiseOnSuspend` and  `suspendOnReturnedPromise` functions we add to the `WebAssembly` namespace.

When a wrapped export is invoked it is given the `Suspender` to use for that invocation. That `Suspender` is also used when invoking the wrapped import function. This involves communicating the `Suspender` object received by the export function through to the appropriate imports that that export invokes. This is typically more difficult to achieve without good tooling support when generating the WebAssembly module.

Of course, there are many details being skimmed over, such as the fact that if a synchronous export calls an asynchronous import then the program will trap if the import tries to suspend.
The following provides a more detailed specification as well as some implementation strategy.

## Specification

A `Suspender` is in one of the following states:
* **Inactive** - not being used at the moment
* **Active**[`caller`] - control is inside the `Suspender`, with `caller` being the function that called into the `Suspender` and is expecting an `externref` to be returned
* **Suspended** - currently waiting for some promise to resolve

We separate the specifications of the `Suspender` interface and the static `suspendOnPromise` and `returnPromiseOnSuspend` functions.

The method `suspender.returnPromiseOnSuspend(func)` asserts that `func` is a `WebAssembly.Function` with a function type of the form `[ti*] -> [to]` and then returns a `WebAssembly.Function` with function type `[ti*] -> [externref]` that does the following when called with arguments `args`:

1. Traps if `suspender`'s state is not **Inactive**
2. Changes `suspender`'s state to **Active**[`caller`] (where `caller` is the current caller)
3. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
4. Asserts that `suspender`'s state is **Active**[`caller'`] for some `caller'` (should be guaranteed, though the caller might have changed)
5. Changes `suspender`'s state to **Inactive**
6. Returns (or rethrows) `result` to `caller'`

Note that the `Suspender.returnPromiseOnSuspend` method takes a `WebAssembly.Function` as argument and returns a `WebAssembly.Function` value. This reflects the constraint that this API may only be used to integrate WebAssembly computations within a JavaScript environment. If the argument is not a `WebAssembly.Function`, or if that entity does not actually contain a WebAssembly function, then a `TypeError` exception is thrown.

The method `suspender.suspendOnReturnedPromise(func)` asserts that `func` is a `WebAssembly.Function` object with a function type of the form `[t*] -> [externref]` and returns a `WebAssembly.Function` with function type `[t*] -> [externref]` which does the following when called with arguments `args`:

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

The static function `returnPromiseOnSuspend(func)` asserts that `func` is a `WebAssembly.Function` with a function type of the form `[ti*] -> [to]` and then returns a `WebAssembly.Function` with function type `[externref ti*] -> [externref]` that does the following when called with arguments `suspender` followed by `args`:

1. Traps if `suspender`'s state is not **Inactive**
2. Changes `suspender`'s state to **Active**[`caller`] (where `caller` is the current caller)
3. Lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
4. Asserts that `suspender`'s state is **Active**[`caller'`] for some `caller'` (should be guaranteed, though the caller might have changed)
5. Changes `suspender`'s state to **Inactive**
6. Returns (or rethrows) `result` to `caller'`

The static function `suspendOnReturnedPromise(func)` asserts that `func` is a `WebAssembly.Function` object with type of the form `[t*] -> [externref]` and returns a `WebAssembly.Function` with function type `[externref t*] -> [externref]` that does the following when called with arguments `suspender` followed by `args`:

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

## Frequently Asked Questions

1. **What is the purpose of the `Suspender` object?**

   The `Suspender` object is used to connect a `Promise` returning import with a `Promise` returning export. Without this explicit connection, it becomes problematic especially when constructing so-called chains of modules: where one module calls into the exports of another.

1. **Why do we try to prevent JavaScript programs from using this API?**

   JavaScript already has a way of managing computations that can suspend. This is semantically connected to JavaScript `Promise` objects and the `async` function syntax. However, a more important reason is that it is important, in the context of JavaScript, that we do not introduce language features that can affect the behavior of existing programs.

1. **Why does the API only apply t `WebAssembly.Function` values, and not `Function`s?**

   The core interface elements in this API refer to the use of `WebAssembly.Function` entities rather than plain `Function` entities. There are some potential questions and issues about this choice:

    * Compared to regular imports, it is arguably less ergonomic to manually mark the types of a function when importing a JavaScript function as a wrapped import. This is not needed for normal imports, but we are requiring it for wrapped imports.
    * A wrapped import function is not callable from JavaScript. The role of a wrapped import is fundamentally to signal intentions to the process of instantiating modules. It is arguable that using wrapper functions in this way may not be the best architectural approach to addressing this signaling.

1. **Which is better: the shared `Suspender` object or the static functions?**

   Using a shared `Suspender` object that connects exports and imports at module instantiation time is significantly easier to use than the static version. The reason for this is that wrapping imports and exports using `WebAssembly.suspendOnReturnedPromise` and `WebAssembly.returnPromiseOnSuspend` require that the `Suspender` object is threaded through the computation. In particular, a `Suspender` object must be given as an additional argument to the export, and that that same `Suspender` object must be presented to the import. This requires some internal reorganization of the WebAssembly module to ensure the transmission of the object&mdash;which is an `externref` from the perspective of WebAssembly and so managing this may be complex.

   However, the WebAssembly wrappers allow for program reentrancy&mdash;which makes it simpler to construct responsive applications. We anticipate that hand built WebAssembly applications will likely use the simpler `Suspender.suspendOnReturnedPromise` API and compilers that already know how to compile asynchronous code will use the `WebAssembly.suspendOnReturnedPromise` API.

1. **Can the two APIs be mixed?**

    For example, by wrapping an export with `Suspender.returnPromiseOnSuspend` while wrapping the imports with `WebAssembly.suspendOnReturnedPromise`.

    In principle, this should work; however, there does not appear to be any benefit from mixing the API styles in this way.

