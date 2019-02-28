using Logging, LinearAlgebra, RCall, DataFrames, StatsModels, Random, BenchmarkTools

function d_criterion(model_matrix::Array{Float64, 2})
    det((model_matrix' * model_matrix) / size(model_matrix, 1)) ^ (1 / size(model_matrix, 2))
end

function linear_model(data::DataFrame)
    linear_formula = Expr(:call)
    linear_formula.args = vcat(:+, names(data))
    #@eval @formula(_ ~ 0 + $linear_formula)
    @eval @formula(_ ~ $linear_formula)
end

function variance_prediction!(dispersion_matrix::Array{Float64, 2},
                              model_matrix::Array{Float64, 2},
                              candidate_set::Array{Float64, 2},
                              design_variance::Array{Float64, 1},
                              candidate_variance::Array{Float64, 1},
                              predictions::Array{Float64, 2},
                              deltas::Array{Float64, 2})
    @inbounds Threads.@threads for i = 1:size(model_matrix, 1)
        design_variance[i] = model_matrix[i, :]' * dispersion_matrix * model_matrix[i, :]
    end

    @inbounds Threads.@threads for i = 1:size(candidate_set, 1)
        candidate_variance[i] = candidate_set[i, :]' * dispersion_matrix * candidate_set[i, :]
    end

    @inbounds Threads.@threads for i = 1:size(predictions, 1)
        @inbounds for j = 1:size(predictions, 2)
            predictions[i, j] = model_matrix[i, :]' * dispersion_matrix * candidate_set[j, :]
        end
    end

    @inbounds Threads.@threads for i = 1:size(deltas, 1)
        @inbounds for j = 1:size(deltas, 2)
            deltas[i, j] = candidate_variance[j] - design_variance[i] -
                           ((design_variance[i] * candidate_variance[j]) -
                            (predictions[i, j] * predictions[i, j]))
        end
    end

    return
end

function random_design(factors::Int, size::Int)
    data = Dict("_" => ones(size))

    for i in 1:factors
        data["X$i"] = rand(size)
    end

    DataFrame(data)
end

function remove_response(design::DataFrame, model_matrix::ModelMatrix)
    response_index = findfirst(x -> x == :_, names(design))
    removed_column = findfirst(x -> x == response_index, model_matrix.assign)

    clean_columns = trues(size(model_matrix.m, 2))
    clean_columns[removed_column] = false

    model_matrix.m[:, clean_columns]
end

function optimize_random_starting_design(;factors::Int,
                                         experiments::Int,
                                         candidate_set_size::Int,
                                         iterations::Int,
                                         refresh_candidate_set::Bool = true)
    design = random_design(factors, experiments)
    candidate_set = random_design(factors, candidate_set_size)

    formula = linear_model(design)

    model_matrix = ModelMatrix(ModelFrame(formula, design))
    candidate_model_matrix = ModelMatrix(ModelFrame(formula, candidate_set))

    clean_model_matrix = remove_response(design, model_matrix)
    clean_candidate_model_matrix = remove_response(design, candidate_model_matrix)

    design_variance = similar(clean_model_matrix[:, 1])
    candidate_variance = similar(clean_candidate_model_matrix[:, 1])

    predictions = similar(clean_candidate_model_matrix[:, 1],
                          (size(clean_model_matrix, 1),
                           size(clean_candidate_model_matrix, 1)))

    deltas = similar(clean_candidate_model_matrix[:, 1],
                     (size(clean_model_matrix, 1),
                      size(clean_candidate_model_matrix, 1)))

    dispersion_matrix = inv(clean_model_matrix' * clean_model_matrix)

    variance_prediction!(dispersion_matrix,
                         clean_model_matrix,
                         clean_candidate_model_matrix,
                         design_variance,
                         candidate_variance,
                         predictions,
                         deltas)

    current_d_criterion = d_criterion(clean_model_matrix)
    @info "Starting D-Criterion" current_d_criterion

    for i in 1:iterations
        best_swap = findmax(deltas)
        @debug "Best Swap" best_swap

        if best_swap[1] <= 0.0
            @debug "Max. delta was less than, or equal to, zero"

            if refresh_candidate_set
                @info "Regenerating candidate set..." i

                candidate_set = random_design(factors, candidate_set_size)
                formula = linear_model(candidate_set)
                candidate_model_matrix = ModelMatrix(ModelFrame(formula, candidate_set))
                clean_candidate_model_matrix = remove_response(design, candidate_model_matrix)
            else
                @info "Stopping..."
                break
            end
        else
            clean_model_matrix[best_swap[2][1], :] = clean_candidate_model_matrix[best_swap[2][2], :]
        end

        dispersion_matrix = inv(clean_model_matrix' * clean_model_matrix)

        variance_prediction!(dispersion_matrix,
                             clean_model_matrix,
                             clean_candidate_model_matrix,
                             design_variance,
                             candidate_variance,
                             predictions,
                             deltas)
    end

    current_d_criterion = d_criterion(clean_model_matrix)
    @info "Final D-Criterion" current_d_criterion

    clean_model_matrix
end

function measure_optimize_random_starting_design(refresh_candidate_set)
    Random.seed!(1234)
    #Random.seed!()

    factors = 4
    experiments = 12
    candidate_set_size = 1000
    iterations = 40

    optimized_design = optimize_random_starting_design(factors = factors,
                                                       experiments = experiments,
                                                       candidate_set_size = candidate_set_size,
                                                       iterations = iterations,
                                                       refresh_candidate_set = refresh_candidate_set)
end

design = measure_optimize_random_starting_design(false)
design_refresh = measure_optimize_random_starting_design(true)