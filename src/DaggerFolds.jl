module DaggerFolds

export DaggerEx, foldx_dagger, transduce_dagger

import FLoops
using Dagger: delayed
using SplittablesBase: amount, halve
using Transducers:
    Reduced, Transducer, combine, complete, foldl_nocomplete, reduced, start, unreduced

# TODO: Don't import internals from Transducers:
using Transducers:
    DefaultInit, DefaultInitOf, EmptyResultError, IdentityTransducer, maybe_usesimd, restack

"""
    foldx_dagger(op[, xf], xs; init, simd, basesize)
    transduce_dagger(op[, xf], init, xs; simd, basesize)

Extended distributed fold backed up by Dagger.
"""
(foldx_dagger, transduce_dagger)

const SIMDFlag = Union{Bool,Symbol,Val{true},Val{false},Val{:ivdep}}

issmall(reducible, basesize) = amount(reducible) <= basesize

foldx_dagger(op, xs; init = DefaultInit, kwargs...) =
    unreduced(transduce_dagger(op, init, xs; kwargs...))

foldx_dagger(op, xf, xs; init = DefaultInit, kwargs...) =
    unreduced(transduce_dagger(xf, op, init, xs; kwargs...))

transduce_dagger(xf::Transducer, op, init, xs; kwargs...) =
    transduce_dagger(xf'(op), init, xs; kwargs...)

function transduce_dagger(
    rf,
    init,
    xs;
    simd::SIMDFlag = Val(false),
    basesize::Union{Integer,Nothing} = nothing,
)
    thunk = _delayed_reduce(
        maybe_usesimd(rf, simd),
        init,
        xs,
        max(1, basesize === nothing ? amount(xs) ÷ Threads.nthreads() : basesize),
    )
    acc = collect(thunk)
    result = complete(rf, acc)
    if unreduced(result) isa DefaultInitOf
        throw(EmptyResultError(rf))
    end
    return result
end

function _delayed_reduce(rf, init, xs, basesize)
    if amount(xs) <= basesize
        return delayed(_reduce_basecase)(rf, init, xs)
    end
    left, right = halve(xs)
    a = _delayed_reduce(rf, init, left, basesize)
    b = _delayed_reduce(rf, init, right, basesize)
    return delayed(_combine)(rf, a, b)
end

@noinline _reduce_basecase(rf::F, init::I, reducible) where {F,I} =
    restack(foldl_nocomplete(rf, start(rf, init), reducible))

# Semantically correct but inefficient (eager) handling of `Reduced`.
# Not sure how to cancel `delayed` computation.
_combine(rf, a::Reduced, b::Reduced) = a
_combine(rf, a::Reduced, b) = a
_combine(rf::RF, a, b::Reduced) where {RF} = reduced(combine(rf, a, unreduced(b)))
_combine(rf::RF, a, b) where {RF} = combine(rf, a, b)

"""
    DaggerEx(; simd, basesize)

FLoops executor implemented using Dagger.jl.
"""
struct DaggerEx{K} <: FLoops.Executor
    kwargs::K
end

FLoops._fold(rf::RF, init, xs, exc::DaggerEx) where {RF} =
    foldx_dagger(rf, IdentityTransducer(), xs; exc.kwargs..., init = init)

end
