# JavaScript-Promise Integration Proposal

## Summary

The JavaScript Promise Integration (JSPI) API is an API that bridges the gap between synchronous WebAssembly applications and asynchronous Web APIs. It does so by mapping synchronous calls issued by the WebAssembly application into asynchronous Web API calls, suspending the application and resuming it when the asynchronous I/O operation is completed. Crucially, we are able to achieve this with very few changes to the WebAssembly application itself.

This proposal makes no changes to the JavaScript language nor to the WebAssembly language. There are no new WebAssembly instructions or types specified. Semantically, all of the changes outlined are at the boundary between WebAssembly and JavaScript.

## Motivation

Many modern APIs on the Web are *asynchronous* in nature -- mediated by `Promise`s. Asynchronous APIs operate by splitting the offered functionality into two separate parts: the initiation of the operation and its resolution; with the latter coming some time after the first. Most importantly, the application continues execution after kicking off the operation; and is then notified when the operation completes.

For example, the `fetch` API allows Web applications to access the contents associated with a URL; however, the `fetch` function does not directly return the results of the fetch; instead it returns a `Promise`. The connection between the fetch response and the original request is reestablished by attaching a *callback* to that `Promise`. The callback function can inspect the response, collect the data (if it is there of course) and re-enter the Web application.

On the other hand, many applications that are compiled into WebAssembly originate from languages such as C/C++ which do not have mature coroutining features and where the APIs used are typically *synchronous* in nature. In the example of calling `fetch`, a legacy application would typically *block* until the result of the `fetch` is available. Web applications are strongly discouraged from blocking in this way; because blocking the main thread carries the risk of degrading the user experience. As a result there can be a significant mismatch between the application and web APIs.

This proposal allows a WebAssembly application to interact with JavaScript APIs and functions that are oriented around `Promise`s. Furthermore, it allows the WebAssembly application to invoke so-called `Promise`-bearing imports and access the value of the `Promise`, without having to explicitly manage the asynchronous callbacks normally associated with `Promise`s.

## Core concepts

There are two functions in the JSPI API: `WebAssembly.suspending` and `WebAssembly.promising`, together with a special object that is used to *mark* certain imports.

The `WebAssembly.suspending` function is used to mark imports to a WebAssembly module such that, when called, the WebAssembly code will suspend until the `Promise` returned by the import is resolved.[^imports]

[^imports]: By *imports*, we include not only the imports provided when a WebAssembly module is instantiated but also when the WebAssembly module's function table is adjusted by JavaScript code and when a function is returned into the module as a result of calling from WebAssembly into JavaScript.

When, at some point later, the `Promise` is resolved, and the WebAssembly module is *resumed* -- by the browser's event queue task runner --  then the value of the resolved `Promise` becomes the value of the WebAssembly call to the import.

Again, if the `Promise` is rejected, then instead of resuming the WebAssembly module with the value, an exception will be propagated into the suspended computation.

The `WebAssembly.promising` function is used to wrap an exported WebAssembly function into one that returns a `Promise` -- where the returned value from the exported function becomes the basis of resolving the `Promise`.[^wrapping]

[^wrapping]: The English language can be somewhat ambiguous when it comes to concepts such as marking and wrapping. In order to avoid such ambiguities, we use the term *marked function* to denote the result of applying `WebAssembly.promising` or `WebAssembly.suspending` to a function. And we will use the term *wrapped function* to denote the argument function that is passed into those API calls -- i.e., the function that will be invoked as a result of invoking the marked function.

As a result, a WebAssembly module can import a `suspending` function that wraps an async JavaScript function so that the WebAssembly module's computation suspends until the `Promise` is resolved, letting the WebAssembly code treat the call as a synchronous call.

The `promising` and `suspending` functions form a pair; when a WebAssembly computation is suspended due to a call to a `suspending` import, it is the call to the `promising` export that is continued -- in the first instance. I.e., a call to a `promising` export finishes when the first call to a `suspending` import results in the WebAssembly code being suspended. The value returned by the `promising` export is also a `Promise`; that will be resolved only when the wrapped export finally returns (or throws an exception).

>Of course, in general, a particular call to a marked export may require multiple calls to `suspending` imports, with multiple suspensions. However, other than the first one, all subsequent suspensions are visible only to the browser event queue task runner: the host application only sees the `Promise` initially created and is reactivated only when the wrapped export finally returns (or throws).

Since they form a pair, it not expected for an unmatched module to be meaningful: if a marked import suspends but the corresponding export (whose execution led to the call to the suspending import) is not marked then the engine is expected to *trap*. If an export function is marked, but its execution never results in a call to a marked import, then the marked function returns a fully resolved `Promise`.

### Restriction

Only WebAssembly computations may be suspended using JSPI; this is enforced by requiring that only WebAssembly frames are active between the call to a `promising` function and any call to a `suspending` function.

## Examples

Considering the expected applications of this API, we can consider two simple scenarios: that of a so-called *legacy C* application -- which is written in the style of a non-interactive application using synchronous APIs for reading and writing files -- and the *responsive C* application; where the application was typically written using an eventloop internal architecture but still uses synchronous APIs for I/O.

### Supporting Access to Asynchronous Functions

Our first example looks quite trivial, with the WebAssembly module:

```wasm
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

In this example, we have a WebAssembly module that is a very simple state machine—driven from JavaScript. Whenever the JavaScript client code wishes to update the state, it invokes the exported `update_state` function. In turn, the WebAssembly `update_state` function calls an import, `compute_delta`, to compute a delta to add to the state.

On the JavaScript side, though, the function we want to use for computing the delta turns out to need to be run asynchronously; that is, it returns a `Promise` of a `Number` rather than a `Number` itself. In addition, we want to implement the `compute_delta` import by using JavaScript `fetch` to get the delta from the url `www.example.com/data.txt`.

This expectation is reified in the JavaScript code for `compute_delta`:

```js
var compute_delta = () => 
  fetch('https://example.com/data.txt')
    .then(res => res.text())
    .then(txt => parseFloat(txt));
```

In order to prepare our code for asynchrony, we wrap the `compute_delta` function using `WebAssembly.suspending` function:

```js
var suspending_compute_delta = WebAssembly.suspending(compute_delta);
```

The complete import object looks like:

```js
var init_state = () => 2.71;
var importObj = {js: {
    init_state: init_state,
    compute_delta:suspending_compute_delta}};
```

In addition to preparing the import, we must also handle the export side. The process of wrapping exports is a little different to wrapping imports; in part because we prepare imports before instantiating modules and we wrap exports afterwards:

```js
var sampleModule = WebAssembly.instantiate(demoBuffer,importObj);
var promise_update = WebAssembly.promising(sampleModule.exports.update_state)
```

At runtime, a call to the JavaScript function `promise_update` will get a `Promise`. As part of resolving that `Promise`,  the WebAssembly exported `$update_state` function is called, which results in a call to the `$compute_delta` import. That, in turn, uses `fetch` to access a remote file, and parse the result in order to give the actual floating point value back to the WebAssembly module. Since we use the wrapped `suspending_compute_delta` to implement `$compute_delta`, the import call will be suspended.

When the `fetch` completes, the result is parsed -- which will likely also cause a suspension since getting the text from a `Response` also results in a `Promise`. This too will cause the application to be suspended; but when that finally is resumed the text is parsed and the result returned as a float to `$compute_delta`. 

After updating the internal state, the original export `$update_state` returns, which causes the `Promise` originally returned by `promise_update` to be resolved. At that point, anyone awaiting that `Promise` will be given the value returned by `$update_state`.

### Supporting Responsive Applications with Reentrancy

A responsive application is able to respond to new requests even while suspended for existing ones. Note that we are not concerned with *multi-threaded* applications (which can also be responsive): only one computation is expected to be active at any one time and all others would be *suspended*. Typically, such responsive applications are already crafted using an eventloop style architecture; even if they still use synchronous APIs.

In fact, our example above is already technically re-entrant! We can call `promise_update` even before other calls to `promise_update` have returned. However, JSPI does not guarantee that the updates are completed in any particular order: it is up to the application developer to ensure that this is safe. In our specific case, it does not matter because all the fetch calls result in the same floating point number being accumulated to the `$state` global variable.

Not all applications can equally tolerate being reentrant in this way. Certainly, languages in the C family do not make this straightforward. In fact, an application would typically have to have been engineered appropriately, by, for example, ensuring that each call to a suspending import does not interfere with globally shared state.

However, desktop applications, written for operating systems such as Mac OS and Windows, are often already structured in terms of an event loop that monitors input events and schedules UI effects. Such an application can often make good use of JSPI: perhaps by removing the application's event loop and replacing it with the browser's event loop.

## Specification

### WebIDL Interface

```idl
[Exposed=(Window,Worker,Worklet)]
partial namespace WebAssembly {

  Function promising(WebAssembly.Function fun);

  Suspending suspending(Function fun);

  interface Suspending {
    [Internal]Function wrappedFunction;
  }
}
```

The `Suspending` object's role is primarily to annotate a function in a way that enables the `WebAssembly.instantiate` function to implement the import in a special way.

#### `WebAssembly.suspending`

The `WebAssembly.suspending` function takes a JavaScript `Function` as an argument and returns a `WebAssembly.Suspending` object. Note that `WebAssembly.Suspending` has no externally visible attributes other than those inherited from `Object`. However, it does have an internal attribute -- the `wrappedFunction` -- which is referenced in the specifics of the algorithm below.

>Note the argument to `WebAssembly.suspending` is assumed to be a *JavaScript function*. I.e., even if a `WebAssembly.Function` is passed to `WebAssembly.suspending`, it is interpreted as a JavaScript function. This allows us to ignore certain so-called corner cases in the usage of JSPI: in particular there is no special handling of calling WebAssembly functions that may return `Promise`s.

#### `WebAssembly.promising`

The `WebAssembly.promising` function takes a WebAssembly function -- i.e., not a JavaScript function -- and converts it to a JavaScript function that returns a `Promise`.

### Suspendable functions

>In the following description we use the term *execution context* to denote a potentially suspendable computation. This should not be confused with other uses of the term.

We modify the *read-the-imports* algorithm in the WebAssembly [JS-API](https://webassembly.github.io/spec/js-api/index.html#read-the-imports) specification to account for functions marked as `Suspending`. In particular, we add the clause:

1. Let *`o`* be `$Get$`(*`importObject`*, *`moduleName`*).
1. If *`o`* is of the form *Suspendable*,
  1.  Let *`v`* be  `$Get$`(*`o`*, *`wrappedFunction`*).
    1. If `$IsCallable$`(*`v`*) is false, throw a `LinkError` exception.
      1. Create a *suspending function* from *`v`* and *`functype`*, and let *`funcaddr`* be the result.
  1. Let *`externfunc`* be the external value *`funcaddr`*
  1. Append *`externfunc`* to *`imports`*.

The *suspending function* is a function whose behavior is determined as follows:

1. Let `context` refer to the execution context that is current at the time of a call to the *suspending function*. Let `func` be the wrapped function that was used when creating the *suspending function*.
1. Traps if `context`'s state is not **Active**[`caller`] for some `caller`
1. Let `result` be the result of calling `func(args)` (or any trap or thrown exception) where `args` are the additional arguments passed to the call when the imported function was called from the WebAssembly module.
1. Let `promise` be the result of:
   1. If `result` is a normal result, then invoke `Promise.resolve`(`result`)
      >Note: if `result` already is a `Promise`, then this is equivalent to setting `promise` to `result`.
   2. If `result` is an exception or error, then invoke `Promise.reject`(`result`)  
1. Lets `frames` be the stack frames since `caller`
1. Traps if there are any frames of non-WebAssembly functions in `frames`
1. Changes `context`'s state to **Suspended**
1. Returns the result of `promise.then(onFulfilled, onRejected)` with functions `onFulfilled` and `onRejected` that do the following:
   1. Asserts that `context`'s state is **Suspended** (should be guaranteed)
   2. Changes `context`'s state to **Active**[`caller'`], where `caller'` is the caller of `onFulfilled`/`onRejected`
   3. * In the case of `onFulfilled`, converts the given value to `externref` and returns that to `frames`
      * In the case of `onRejected`, throws the given value up to `frames` as an exception according to the JS API of the [Exception Handling](https://github.com/WebAssembly/exception-handling/) proposal.

### Exporting Promises

The `WebAssembly.promising` function is used to create a JavaScript `Promise` returning function from a function exported from a WebAssembly instance.

0. Let `func` be the exported WebAssembly function that is passed to the `WebAssembly.promising` function,
1. create a function that will, when called with arguments `args`:
    1. Let `promise` be a new `Promise` constructed as though by the `Promise`(`fn`) constructor, where `fn` is a function of two arguments `accept` and `reject` that:
        1. lets `context` be a new execution context.
        2. sets the state of `context` to **Active**[`caller`] (where `caller` is the current caller)
        3. lets `result` be the result of calling `func(args)` (or any trap or thrown exception)
        4. asserts that `context`'s state is **Active**[`caller'`] for some `caller'` (should be guaranteed, though the caller might have changed)
        5. releases the execution `context`, which includes releasing any execution resources associated with the context.
        6. If `result` is not an exception or a trap, calls the `accept` function argument with the appropriate value.
        7. If `result` is an exception, or if it is a trap, calls the `reject` function with the raised exception.
    2. Returns `promise` to `caller`
2. Return created function as value of `WebAssembly.promising`

Note that, if the inner function `func` suspends (by invoking a `Promise` returning import), then the `promise` will be returned to the `caller` before `func` returns. When `func` completes eventually, then `promise` will be resolved -- and one of `accept` or `reject` will be invoked by the browser's microtask runner.

## Frequently Asked Questions

1. **Why do we prevent JavaScript programs from using this API?**

   JavaScript already has a way of managing computations that can suspend. This is semantically connected to JavaScript `Promise` objects and the `async` function syntax. However, a more important reason is that we do not wish to inadvertently introduce features that can affect the behavior of existing JavaScript programs.

1. **Why does `WebAssembly.promising` return a JavaScript `Function`**?

   This allows us to be more precise in a few special cases. In particular, if two WebAssembly modules (Modules A & B) are *chained together* (e.g., the import of module A is provided by the export of module B) then we need precision about the interaction with JSPI:
    1. If the link is composed of a `promising`/`suspending` pair (i.e., the module A import is wrapped with a call to `WebAssembly.suspending` and the module B export is wrapped with `WebAssembly.promising`) then, if module B suspends (via one of its imports), then module A will also suspend. However, there will also be an additional `Promise`: created from the wrapped export from module B.
    1. If the link is direct -- without a `promising`/`suspending` pair -- then the connect is transparent from the perspective of JSPI; provided that there are no JavaScript function calls in the link.
