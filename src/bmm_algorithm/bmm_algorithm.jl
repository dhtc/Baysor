using DataFrames
using Distributions
using NearestNeighbors
using StatsBase

using Base.Threads
using Dates: now

import DistributedArrays

function drop_unused_components!(data::BmmData; min_n_samples::Int=2, force::Bool=false)
    non_noise_ids = findall(data.assignment .> 0)
    existed_ids = [i for (i,c) in enumerate(data.components) if (c.n_samples >= min_n_samples || (!c.can_be_dropped && !force))]
    id_map = zeros(Int, length(data.components))
    id_map[existed_ids] = 1:length(existed_ids)

    data.assignment[non_noise_ids] = id_map[data.assignment[non_noise_ids]]
    data.components = data.components[existed_ids]

    @assert all(num_of_molecules_per_cell(data) .== [c.n_samples for c in data.components])
end

# point is adjacent to itself
adjacent_component_ids(assignment::Array{Int, 1}, adjacent_points::Array{Int, 1})::Array{Int, 1} =
    [x for x in Set(assignment[adjacent_points]) if x > 0]

"""
...
# Arguments
- `assignment::Array{Int, 1}`: 
- `adjacent_points::Array{Int, 1}`: 
- `adjacent_weights::Array{Float64, 1}`: weights here mean `1 / distance` between two adjacent points
"""
function adjacent_component_weights(assignment::Array{Int, 1}, adjacent_points::Array{Int, 1}, adjacent_weights::Array{Float64, 1})
    component_weights = Dict{Int, Float64}()
    for (c_id, cw) in zip(assignment[adjacent_points], adjacent_weights)
        if c_id == 0
            continue
        end

        component_weights[c_id] = get(component_weights, c_id, 0.0) + cw
    end

    return collect(keys(component_weights)), collect(values(component_weights))
end

function expect_dirichlet_spatial!(data::BmmData, adj_classes_global::Dict{Int, Array{Int, 1}}=Dict{Int, Array{Int, 1}}(); stochastic::Bool=true, noise_density_threshold::Float64=1e-30)
    for i in 1:size(data.x, 1)
        x, y, gene, confidence = (data.x[i, [:x, :y, :gene, :confidence]]...,)
        adj_classes, adj_weights = adjacent_component_weights(data.assignment, data.adjacent_points[i], data.adjacent_weights[i])

        adj_global = get(adj_classes_global, i, Int[]);
        if length(adj_global) > 0
            append!(adj_classes, adj_global)
            append!(adj_weights, ones(length(adj_global)) .* data.real_edge_weight)
        end

        denses = confidence .* adj_weights .* [c.prior_probability * pdf(c, x, y, gene) for c in data.components[adj_classes]]

        if sum(denses) < noise_density_threshold
            assign!(data, i, 0) # Noise class
            continue
        end

        if confidence < 1.0
            append!(denses, (1 - confidence) * data.real_edge_weight * data.noise_density)
            append!(adj_classes, 0)
        end

        if !stochastic
            assign!(data, i, adj_classes[findmax(denses)[2]])
            continue
        end

        assign!(data, i, sample(adj_classes, Weights(denses)))
    end
end

function update_prior_probabilities!(components)
    c_weights = [max(c.n_samples, c.prior_weight) for c in components]
    v = [rand(Beta(1 + n, n_sum)) for (n, n_sum) in zip(c_weights[1:end-1], cumsum(c_weights[end:-1:2])[end:-1:1])];

    prior_probs = vcat(1, cumprod(1 .- v[1:end-1])) .* v;
    push!(prior_probs, 1 - sum(prior_probs));

    for (c, p) in zip(components, prior_probs)
        c.prior_probability = p
    end
end

function maximize!(c::Component, pos_data::Array{Float64, 2}, comp_data::Array{Int, 1}, data::BmmData)
    c.n_samples = size(pos_data, 2)

    if size(pos_data, 2) == 0
        return maximize_from_prior!(c, data)
    end

    return maximize!(c, pos_data, comp_data)
end

function maximize_prior!(data::BmmData, min_molecules_per_cell::Int)
    if data.update_priors == :no
        return
    end

    components = (data.update_priors == :all) ? data.components : filter(c -> !c.can_be_dropped, data.components)
    components = filter(c -> c.n_samples >= min_molecules_per_cell, components)

    if length(components) < 2
        return
    end

    mean_shape = vec(median(hcat([eigen(shape(c.position_params)).values for c in components]...), dims=2))
    set_shape_prior!(data.distribution_sampler, mean_shape)

    for c in data.components
        set_shape_prior!(c, mean_shape)
    end
end

function maximize!(data::BmmData, min_molecules_per_cell::Int)
    ids_by_assignment = split(collect(1:length(data.assignment)), data.assignment .+ 1)[2:end]
    append!(ids_by_assignment, [Int[] for i in length(ids_by_assignment):length(data.components)])

    pos_data_by_assignment = [position_data(data)[:, p_ids] for p_ids in ids_by_assignment]
    comp_data_by_assignment = [composition_data(data)[p_ids] for p_ids in ids_by_assignment]

    # @threads for i in 1:length(data.components)
    for i in 1:length(data.components)
        # data.components[i] = maximize(data.components[i], pos_data_by_assignment[i], comp_data_by_assignment[i])
        maximize!(data.components[i], pos_data_by_assignment[i], comp_data_by_assignment[i], data)
    end
    # data.components = pmap(v -> maximize(v...), zip(data.components, pos_data_by_assignment, comp_data_by_assignment))

    maximize_prior!(data, min_molecules_per_cell)

    data.noise_density = estimate_noise_density_level(data)
end

function estimate_noise_density_level(data::BmmData)
    composition_density = mean([mean(c.composition_params.counts[c.composition_params.counts .> 0] ./ c.composition_params.n_samples) for c in data.components])

    eigen_vals = data.distribution_sampler.shape_prior.eigen_values;
    position_density = pdf(MultivariateNormal([0.0, 0.0], diagm(0 => eigen_vals)), 3 .* (eigen_vals .^ 0.5))

    return position_density * composition_density
end

function append_empty_components!(data::BmmData, new_component_frac::Float64, adj_classes_global::Dict{Int, Array{Int, 1}})
    for i in 1:round(Int, new_component_frac * length(data.components))
        new_comp = sample_distribution(data)
        push!(data.components, new_comp)

        cur_id = length(data.components)
        for t_id in data.adjacent_points[knn(data.position_knn_tree, new_comp.position_params.μ, 1)[1][1]]
            if t_id in keys(adj_classes_global)
                push!(adj_classes_global[t_id], cur_id)
            else
                adj_classes_global[t_id] = [cur_id]
            end
        end
    end
end


function bmm!(data::BmmData; min_molecules_per_cell::Int, n_iters::Int=1000, log_step::Int=4, verbose=true, history_step::Int=0, new_component_frac::Float64=0.05,
              return_assignment_history::Bool=false, channel::Union{RemoteChannel, Nothing}=nothing)
    ts = now()

    if verbose
        println("EM fit started")
    end

    it_num = 0
    history = BmmData[];
    # neighbors_by_molecule_per_iteration = Array{Array{Array{Int64,1},1}, 1}()
    assignment_per_iteration = Array{Array{Array{Int64,1},1}, 1}()
    adj_classes_global = Dict{Int, Array{Int, 1}}()

    maximize!(data, min_molecules_per_cell)

    for i in 1:n_iters
        if (history_step > 0) && (i.==1 || i % history_step == 0)
            push!(history, deepcopy(data))
        end

        expect_dirichlet_spatial!(data, adj_classes_global)
        maximize!(data, min_molecules_per_cell)

        trace_n_components!(data, min_molecules_per_cell);

        drop_unused_components!(data)

        adj_classes_global = Dict{Int, Array{Int, 1}}()
        append_empty_components!(data, new_component_frac, adj_classes_global)
        update_prior_probabilities!(data.components)

        it_num = i
        if verbose && i % log_step == 0
            println("EM part done for $(now() - ts) in $it_num iterations. #Components: $(length(data.components)). Noise level: $(round(mean(data.assignment .== 0) * 100, digits=3))%")
        end

        if return_assignment_history
            # push!(neighbors_by_molecule_per_iteration, extract_neighborhood_from_assignment(data.assignment))
            push!(assignment_per_iteration, deepcopy(data.assignment))
        end

        if channel !== nothing
            put!(channel, true)
        end
    end

    if verbose
        println("EM part done for $(now() - ts) in $it_num iterations. #Components: $(size(data.components, 1))")
    end

    res = Any[data]
    if history_step > 0
        push!(history, deepcopy(data))
        push!(res, history)
    end

    if return_assignment_history
        # push!(res, neighbors_by_molecule_per_iteration)
        push!(res, assignment_per_iteration)
    end

    if length(res) == 1
        return res[1]
    end

    return res
end

function refine_bmm_result!(bmm_res::BmmData, min_molecules_per_cell::Int; max_n_iters::Int=300, channel::Union{RemoteChannel, Nothing}=nothing)
    for i in 1:max_n_iters
        prev_assignment = deepcopy(bmm_res.assignment)
        drop_unused_components!(bmm_res, min_n_samples=min_molecules_per_cell, force=true)
        expect_dirichlet_spatial!(bmm_res, stochastic=false)
        maximize!(bmm_res, min_molecules_per_cell)

        if channel !== nothing
            put!(channel, true)
        end

        if (minimum(num_of_molecules_per_cell(bmm_res)) >= min_molecules_per_cell) && all(bmm_res.assignment .== prev_assignment)
            if channel !== nothing
                for j in i:max_n_iters
                    put!(channel, true)
                end
            end

            break
        end
    end

    return bmm_res;
end

fetch_bm_func(bd::BmmData) = [bd]

function pmap_progress(func, arr::DistributedArrays.DArray, n_steps::Int, args...; kwargs...)
    p = Progress(n_steps)
    channel = RemoteChannel(()->Channel{Bool}(n_steps), 1)

    exception = nothing
    @sync begin # Parallel progress tracing
        @async while take!(channel)
            next!(p)
        end

        @async begin
            try
                futures = [remotecall(func, procs()[i], arr[i], args...; channel=channel, kwargs...) for i in 1:length(arr)];
                arr = fetch.(wait.(futures))
            catch ex
                exception = ex
            finally
                put!(channel, false)
            end
        end
    end

    if exception !== nothing
        throw(exception)
    end

    return arr
end

function push_data_to_workers(bm_data_arr::Array{BmmData, 1})::DistributedArrays.DArray
    if length(bm_data_arr) > nprocs()
        n_new_workers = length(bm_data_arr) - nprocs()
        @info "Creating $n_new_workers new workers. Total $(nprocs() + n_new_workers) workers."
        addprocs(n_new_workers)
        eval(:(@everywhere using Baysor))
    end

    futures = [remotecall(fetch_bm_func, procs()[i], bm_data_arr[i]) for i in 1:length(bm_data_arr)]

    try
        return DistributedArrays.DArray(futures);
    catch ex
        bds = fetch.(wait.(futures))
        err_idx = findfirst(typeof.(bm_data_arr) .!== Baysor.BmmData)
        if err_idx === nothing
            throw(ex)
        end

        error(bds[err_idx])
    end
end

function run_bmm_parallel(bm_data_arr::Array{BmmData, 1}, n_iters::Int; min_molecules_per_cell::Int, verbose::Bool=true, n_refinement_iters::Int=100, kwargs...)#::Array{BmmData, 1}
    @info "Pushing data to workers"
    da = push_data_to_workers(bm_data_arr)

    @info "Algorithm start"
    bm_data_arr = pmap_progress(bmm!, da, n_iters * length(da); n_iters=n_iters, min_molecules_per_cell=min_molecules_per_cell, verbose=false, kwargs...)

    @info "Pushing data for refinement"
    da = push_data_to_workers(bm_data_arr)

    @info "Refinement"
    bm_data_arr = pmap_progress(refine_bmm_result!, da, n_refinement_iters * length(da), min_molecules_per_cell; max_n_iters=n_refinement_iters)

    @info "Done!"

    return bm_data_arr
end