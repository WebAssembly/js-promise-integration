# JavaScript-Promise Integration Proposal

## Summary

The purpose of this proposal is to provide relatively efficient and relatively ergonimic interop between JavaScript promises and WebAssembly but working under the constraint that the only changes are to the JS API and not to core wasm.

The expectation is that the [Stack-Switching proposal](https://github.com/WebAssembly/stack-switching) will eventually extend core WebAssembly with the functionality to implement the operations we provide in this proposal directly within WebAssembly, along with many other valuable stack-switching operations, but that this particular use case for stack switching had sufficient urgency to merit a faster path via just the JS API.
For more information, please refer to the notes and slides for the [June 28, 2021 Stack Subgroup Meeting](https://github.com/WebAssembly/meetings/blob/main/stack/2021/sg-6-28.md), which details the usage scenarios and factors we took into consideration and summarizes the rationale for how we arrived at the following design.

Following feedback that the Stacks Subgroup had received from TC39, this proposal allows *only* WebAssembly stacks to be suspended&mdash;it makes no changes to the JavaScript language and, in particular, does not indirectly enable support for detached `async`/`await` in JavaScript.

In addition, this proposal does not imply any change to either JavaScript or to the WebAssembly language. There are no new WebAssembly instructions, nor are there any additional WebAssembly types specified. Semantically, all of the changes outlined are at the boundary between WebAssembly and JavaScript.

This proposal depends heavily on the [js-types](https://github.com/WebAssembly/js-types/) proposal, which introduces `WebAssembly.Function` as a subclass of `Function`.

## Interface

The proposal is to extend the `WebAssembly.Function` object with a new class of attributes that reflect additional meta-level information about _how_ a particular function is to be used. Our focus will be on two particular attributes&mdash;`suspending` and `promising`&mdash;however, it is expected that other attribtes may follow&mdash;to support additional use cases not necessarily connected to this proposal.

```
[Exposed=(Window,Worker,Worklet)]
partial namespace WebAssembly {
  enum Position { "first", "last", "none"}; /* A special argument may be the last or the first one */

  dictionary Usage {
    Position suspending = "none"; // By default, functions dont suspend
    Position promising = "none";  // By default, functions dont reify Promises
  }

  [Constructor(FunctionType type, function func, Usage usage)]
  interface Function:global.Function{
    FunctionType type();
    Usage usage();
  }

  interface Suspender {
  }
}
```
## Core Concepts and Usage

The purpose of the `Usage` argument of a `WebAssembly.Function` is to convey how the function should be interpreted in the presence of `Promise`s. The `suspending` attribute of the `Usage` object is interpreted during module instantiation for functions that are _imported_ into a module, and the `promising` attribute is interpreted for functions that are _exported_ from a module.

If the `suspending` attribute is set on an imported function, then the `suspending` function uses the first/last `Suspender` argument to suspend the encompassing WebAssembly computation: if the imported function returns a `Promise`, instead of returning that `Promise` as the value to the WebAssembly module, the function suspends execution. If, at some point later, the `Promise` is resolved, then the WebAssembly module is _resumed_, with the value of the resolved `Promise` passed in to the module as the value of the call to the import.

This way a WebAssembly module can import a `suspending` function that wraps an async JavaScript function so that the WebAssembly module's computation suspends until the `Promise` is resolved, letting the WebAssembly code nearly treat the call as a synchronous call.

But, for that to work, the WebAssembly module needs a way to get a `Suspender` to supply as the first/last argument to the imported function. This is addressed by marking an exported function with the `promising` attribute. The `promising` attribute is used to indicate that the wrapped function should be executed on a new suspendible stack, i.e. a `Suspender`. In addition, the `promising` function will return a `Promise` which will be resolved either with the successful results of the export or rejected if the export throws an exception.

The `Suspender` that the wrapped function is executed on is supplied by the engine as its first/last argument.
This way it can be passed to `suspending` functions down the call stack so that they can suspend all WebAssembly computation up to the respective `promising` function call. At that point, the `promising` function returns a `Promise` that will resolve once the `Promise` that prompted the suspension resolves and the subsequently resumed WebAssembly computation completes.

The `promising` and `suspending` functions form a pair; with the effect that a `Promise` showing up as the value of the `suspending` import being propagated directly to the `promising` export&mdash;without executing any of the instructions of the WebAssembly module. The new `Promise` will, when resumed by the JavaScript event loop, reenter the computation by resuming execution at the point where the import call caused a suspension.

Since they form a pair, it not expected for an unmatched module to be meaningful: if a marked import suspends but the corresponding export (whose execution led to the call to the suspending import) is not marked then the engine is expected to _trap_. If an export function is marked, but its execution never results in a call to a marked import&mdash;or, if none of those calls resulted in a suspension&mdash;then it is as though the export function was not marked with `promising`.

It is the responsibility of the WebAssembly program to ensure that this `Suspender` is passed in to the `suspending` import&mdash;as an additional argument.

`Suspender` objects are _not_ directly visible to either the JavaScript programmer or the WebAssembly programmer. The latter sees them as opaque `externref` values and the former only sees them if they were exported by the WebAssembly module as an exported global variable or passed as an argument to an unmarked import.

In particular, a `suspending` function does not actually pass its first/last argument to its imported function; that argument is only used to suspend the containing computation should the wrapped function return a `Promise`.

## Examples
Considering the expected applications of this API, we can consider two simple scenarios: that of a so-called _legacy C_ application&mdash;which is written in the style of a non-interactive application using synchronous APIs for reading and writing files&mdash;and the _responsive C_ application; where the application was typically written using an eventloop internal architecture but still uses synchronous APIs for I/O.

### Supporting Access to Asynchronous Functions
Our first example looks quite trivial:

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
In this example, we have a WebAssembly module that is a very simple state machine—driven from JavaScript. Whenever the JavaScript client code wishes to update the state, it invokes the exported `update_state` function. In turn, the WebAssembly `update_state` function calls an import, `compute_delta`, to compute a delta to add to the state.

On the JavaScript side, though, the function we want to use for computing the delta turns out to need to be run asynchronously; that is, it returns a `Promise` of a `Number` rather than a `Number` itself. In addition, we want to implement the `compute_delta` import by using JavaScript `fetch` to get the delta from the url `www.example.com/data.txt`.

The `fetch` is reified in the JavaScript code for `compute_delta`:
```
var compute_delta = () => 
  fetch('https://example.com/data.txt')
    .then(res => res.text())
    .then(txt => parseFloat(txt));
```
In order to prepare our code for asynchrony, we must make room for the plumbing of the suspender object. We will do this by using a global variable to store it between the export and import, and we will use helper functions.

The import helper implements the function we want&mdash;`compute_delta`&mdash;in terms of what the module actually imports:
```
   (func "compute_delta")  (result f64)
     (global.get $suspender)
     (return_call $compute_delta_import)
    )
```
and the revised import is:
```
    (import "js" "compute_delta" 
      (func $compute_delta_import (param externref) (result f64)))
```
We prepare the JavaScript `compute_delta` function for our use by constructing a `WebAssembly.Function` object from it, and setting the `suspending` attribute to `first`:
```
var suspending_compute_delta = new WebAssembly.Function(
  {parameters:[],results:['f64']},
  compute_delta,
  {suspending:"first"}
)
```
There are three possiblities for assigning a value to the `suspending` attribute: `"first"`, `"last"` and `"none"`. These relate to which argument of `$compute_delta_import` actually has the suspender. In our case it makes no difference whether we use `"first"` or `"last"` because the are no other arguments. Using `"none"` is a signal that the function is not actually suspending.

The return type of `suspending_compute_delta` is an `"f64"`, because that is what the WebAssembly module is importing. However, the actual function that is executed returns a `Promise` of a `f64`. The importing WebAssembly module never sees that `Promise` object&mdash;it is consumed by the function generated via the `WebAssembly.Function` constructor.

The complete import object looks like:
```
var init_state = () => 2.71;
var importObj = {js: {
    init_state: init_state,
    compute_delta:suspending_compute_delta}};
```
In addition to preparing the import, we must also handle the export side. As with the import, we will use a helper&mdash;`$update_state_export` which has the additional suspender argument. This function takes the suspender&mdash;as an `externref` value&mdash;stores it in the `$suspender` global and then calls our normal `$update_state` function:

```
    (func $update_state_export (export "update_state_export") 
      (param $susp externref)(result f64)
      (local.get $susp)
      (global.set $suspender)
      (return_call $update_state)
    )
```
The process of wrapping exports is a little different to wrapping imports; in part because we prepare imports before instantiating modules and the wrapping of the export is done afterwards:
```
var sampleModule = WebAssembly.instantiate(demoBuffer,importObj);
var update_state = new WebAssembly.function(
  {parameters:[], results:['externref']},
  sampleModule.exports.update_state_export,
  {promising : "first"})
```
The resulting modified module allows the synchronous style application to operate using asynchronous APIs.

At runtime, a call to the exported `$update_state_export` function results in a call to the `$compute_delta` import. 

That, in turn, uses `fetch` to access a remote file, and parse the result in order to give the actual floating point value back to the WebAssembly module.

Since `fetch` returns a `Promise`, the import call will be suspended.

The `Suspender` that was passed to `suspending_computed_delta` was retrieved from the global `$suspender` which was last set by `$update_state_export` using the `Suspender` supplied by the engine in `update_state`, so the engine suspends computation up to that point and returns a `Promise` to the caller of `update_state`.

When the `fetch` completes, the result is parsed&mdash;which will likely also cause a suspension since getting the text from a `Response` also results in a `Promise`. This too will cause the application to be suspended; but when that finally is resumed the text is parsed and the result returned as a float to `$compute_delta`. 

After updating the internal state, the original export `$update_state` returns, which causes `$update_state_export` to return. This time, when it returns, the value is no longer a `Promise`.

This will cause the previously suspended WebAssembly computation to resume.
Once it completes, `$update_state_export` returns at last.
At that point, anyone awaiting the `Promise` that was returned by `update_state` will be given the value returned by `$update_state_export`.

### Supporting Responsive Applications with Reentrancy

A responsive application is able to respond to new requests even while suspended for existing ones. Note that we are not concerned with _multi-threaded_ applications (which can also be responsive): only one computation is expected to be active at any one time and all others would be _suspended_. Typically, such responsive applications are already crafted using an eventloop style architecture; even if they still use synchronous APIs.

In fact, our example above is already technically re-entrant! However, it does suffer from a particular bug: if the export is reentered, while an existing call is suspended, the global variable holding the suspender will need to be properly managed. Specifically, we need to reset that global when a suspended computation is resumed.

This is necessary because the global variable used to communicate the identity of the suspender from the export call to the import is just that&mdash;global. It will be reset every time a call to the export is made. Only one task may be running at any one time, which means that the value of the `$suspender` global will not be changed while the task is running. However, the value of `$suspender` _will_ change if the task is suspended and a new task started. So, we need to ensure that the `$suspender` global is properly reset when a task is resumed.

The change involved is small, since the correct value of the `$suspender` global should be available to the resuming task. It was used in order to pass the suspender to the import, and, unless specifically dropped, is still available to the resuming task on the stack.

The required change is located in the call to `$compute_delta_import`:

```
   (func "compute_delta")  (result f64)
     (local $suspender_copy externref)
     (global.get $suspender)
     (local.tee $suspender_copy)
     (call $compute_delta_import)
     (local.get $suspender_copy)
     (global.set $suspender)
     (return)
    )
```

Not all applications can equally tolerate being reentrant in this way. Certainly, languages in the C family do not make this straightforward. In fact, an application would typically have to have been engineered appropriately, by, for example, ensuring that important global state is properly managed.

However, desktop applications, written for operating systems such as Mac OS and Windows, are often already structured in terms of an event loop that monitors input events and schedules UI effects. Such an application can often make good use of JSPI: perhaps by removing the application's event loop and replacing it with the browser's event loop.

## Specification

The `Suspender` object specified here is not made available to JavaScript via this API. Unless exported via some form of back-channel it will not participate in normal JavaScript execution. However, it does have an internal role within the API and so it is specified.

A `Suspender` is in one of the following states:
* **Moribund** - not available for use.
* **Active**[`caller`] - control is inside the `Suspender`, with `caller` being the function that called into the `Suspender` and is expecting an `externref` to be returned
* **Suspended** - currently waiting for some promise to resolve

Note that within a WebAssembly module, a `Suspender` is typed as an `externref`.

### Suspending Functions

The constructor for `WebAssembly.Function`, when it has a `suspending` attribute in its `usage` dictionary:

* If the value of the `suspending` attribute is `"first"`, the `type` argument of the constructor must be of the form:
  ```
  { parameters: ["externref", t0, .., tn], results: [r0, .., rk]}
  ```
* If the value of the `suspending` attrbute is `"last"`:
  ```
  { parameters: [t0, .., tn, "externref"], results: [r0, .., rk]}
  ```
* If the value of the `suspending` attribute is `"none"`:
  ```
  { parameters: [t0, .., tn], results: [r0, .., rk]}
  ```
The WebAssembly function returned by `WebAssembly.Function` is a function whose behavior is determined as follows:

0. Let `suspender` be the additional argument that is expected to contain a `Suspender` object (with WebAssembly type `externref`). Let `func` be the function that was used when creating the `WebAssembly.Function`. 
1. Let `result` be the result of calling `func(args)` (or any trap or thrown exception) where `args` are the additional arguments passed to the call when the imported function was called from the WebAssembly module.
2. If `result` is not a returned `Promise`, then returns (or rethrows) `result`
3. Traps if `suspender`'s state is not **Active**[`caller`] for some `caller`
4. Lets `frames` be the stack frames since `caller`
5. Traps if there are any frames of non-suspendable functions in `frames`
6. Changes `suspender`'s state to **Suspended**
7. Returns the result of `result.then(onFulfilled, onRejected)` with functions `onFulfilled` and `onRejected` that do the following:
   1. Asserts that `suspender`'s state is **Suspended** (should be guaranteed)
   2. Changes `suspender`'s state to **Active**[`caller'`], where `caller'` is the caller of `onFulfilled`/`onRejected`
   3. * In the case of `onFulfilled`, converts the given value to `externref` and returns that to `frames`
      * In the case of `onRejected`, throws the given value up to `frames` as an exception according to the JS API of the [Exception Handling](https://github.com/WebAssembly/exception-handling/) proposal.

A function is suspendable if it was
* defined by a WebAssembly module,
* returned by `WebAssembly.function`,
* or generated by [creating a host function](https://webassembly.github.io/spec/js-api/index.html#create-a-host-function) for a suspendable function

Importantly, functions written in JavaScript are *not* suspendable, conforming to feedback from members of [TC39](https://tc39.es/), and host functions (except for the few listed above) are *not* suspendable, conforming to feedback from engine maintainers.

### Exporting Promises

The constructor for `WebAssembly.Function`, when it has a `promising` attribute in its `usage` dictionary, and a `type` argument of the form:
```
{ parameters: [t0, .., tn], results: ['externref'']}
```
expects its `func` argument to be a WebAssembly function of type:
```
(params externref t0 .. tn) (results r0 .. rk)
```
if the value of `promising` is `"first"`, or of type:
```
(params t0 .. tn externref) (results r0 .. rk)
```
if the value of `promising` is `"last"`.

If the value of `promising` is `"none"`, then this specification does not apply to the constructed function.

Note that the return type of the `WebAssembly.Function` is fixed to `externref`. This is because the constructed function returns a `Promise`.

0. Let `func` be the function that is passed to the `WebAssembly.Function` constructor, 
1. the function that is created using this variant of the `WebAssembly.Function` constructor will, when called with arguments `args`:
1. Let `promise` be a new `Promise` constructed as though by the `Promise`(`fn`) constructor, where `fn` is a function of two arguments `accept` and `reject` that:
   1. lets `suspender` be a new `Suspender` object and passes it as an additional argument to `args` to the `func` argument in the `WebAssembly.Function` constructor:
      1. If `promising` is `"first"`, then `suspender` is the first argument, followed by `args`;
      2. if `promising` is `"last"`, then `suspender` is the last argument, after `args`.
   2. sets the state of `suspender` to **Active**[`caller`] (where `caller` is the current caller)
   3. lets `result` be the result of calling `func(suspender,...args)` (or any trap or thrown exception)
   4. asserts that `suspender`'s state is **Active**[`caller'`] for some `caller'` (should be guaranteed, though the caller might have changed)
   5. changes `suspender`'s state to **Moribund**. This is also an opportunity to release any execution resources associated with the suspender. A **Moribund** suspender may not be used to suspend computations.
   6. If `result` is not an exception or a trap, calls the `accept` function argument with the appropriate value.
   6. If `result` is an exception, or if it is a trap, calls the `reject` function with the raised exception.
6. Returns `promise` to `caller`

Note that, if the inner function `func` suspends (by invoking a `Promise` returning import), then the `promise` will be returned to the `caller` before `func` returns. When `func` completes eventually, then `promise` will be resolved&mdash;and one of `accept` or `reject` will be invoked by the browser's microtask runner.

## Frequently Asked Questions

1. **What is the purpose of the `Suspender` object?**

   The `Suspender` object is used to connect a `Promise` returning import with a `Promise` returning export. Without this explicit connection, it becomes problematic especially when constructing so-called chains of modules: where one module calls into the exports of another.

   A further issue arises from potential misuse of the imported function. Since imports can be immediately exported when a WebAsembly module is instantiated, a wrapped import can also be exported. However, without being passed an explicit capability to suspend&mdash;in the form of the connecting suspender object&mdash;any attempt to use the wrapped function in a different setting will not compromise the integrity of the export/import pair.
   
   In fact, such a use would either be completely benign&mdash;because it was used in a different module for that module's asynchronous imports&mdash;or it would simply trap or not validate&mdash;because the wrapped import requires a suitable `externref` in order to be callable.

1. **Why do we try to prevent JavaScript programs from using this API?**

   JavaScript already has a way of managing computations that can suspend. This is semantically connected to JavaScript `Promise` objects and the `async` function syntax. However, a more important reason is that it is important, in the context of JavaScript, that we do not introduce language features that can affect the behavior of existing programs.
