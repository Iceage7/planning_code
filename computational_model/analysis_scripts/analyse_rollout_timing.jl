# in this script, we analyse the timing of rollouts in the RL agent
# the resulting 'response times' can then be compared with human behavioural data

## load scripts and model
include("anal_utils.jl")
using ToPlanOrNotToPlan

println("analysing the timings of rollouts in the RL agent")

loss_hp = LossHyperparameters(0, 0, 0, 0) #not computing losses
epoch = plan_epoch #test epoch

for seed = seeds #iterate through models trained independently

    # load the model parameters
    fname = "N100_T50_Lplan8_seed$(seed)_$epoch"
    println("loading ", fname)
    network, opt, store, hps, policy, prediction = recover_model("../models/$fname");

    # instantiate model and environment
    Larena = hps["Larena"]
    model_properties, wall_environment, model_eval = build_environment(
        Larena, hps["Nhidden"], hps["T"], Lplan = hps["Lplan"], greedy_actions = greedy_actions
    )
    m = ModularModel(model_properties, network, policy, prediction, forward_modular)

    # run a bunch of episodes
    Random.seed!(1)
    batch_size = 50000
    tic = time()
    L, ys, rews, as, world_states, hs = run_episode(
        m, wall_environment, loss_hp; batch=batch_size, calc_loss = false
    )

    # extract some data we might need
    states = reduce((a, b) -> cat(a, b, dims = 3), [ws.agent_state for ws = world_states]) #states over time
    wall_loc = world_states[1].environment_state.wall_loc #wall location
    ps = world_states[1].environment_state.reward_location #reward location
    Tmax, Nstates = size(as, 2), Larena^2 #extract some dimensions
    rew_locs = reshape(ps, Nstates, batch_size, 1) .* ones(1, 1, Tmax) #for each time point
    println("average reward: ", sum(rews .> 0.5) / batch_size, "  time: ", time() - tic) #average reward per episode

    # how many steps/actions were planned
    plan_steps = zeros(batch_size, Tmax);
    for t = 1:Tmax-1
        plan_steps[:,t] = sum(world_states[t+1].planning_state.plan_cache' .> 0.5, dims = 2)[:];
    end

    #extract some trial information
    trial_ts = zeros(batch_size, Tmax) # network iteration within trial
    trial_ids = zeros(batch_size, Tmax) # trial number
    trial_anums = zeros(batch_size, Tmax) # action number (not counting rollouts)
    for b = 1:batch_size #iterate through episodes
        Nrew = sum(rews[b, :] .> 0.5) #total number of rewards
        sortrew = sortperm(-rews[b, :]) #indices or sorted array
        rewts = sortrew[1:Nrew] #times at which we got reward
        diffs = [rewts; Tmax+1] - [0; rewts] #duration of each trial
        trial_ids[b, :] = reduce(vcat, [ones(diffs[i]) * i for i = 1:(Nrew+1)])[1:Tmax] #trial number
        trial_ts[b, :] = reduce(vcat, [1:diffs[i] for i = 1:(Nrew+1)])[1:Tmax] #time within trial

        finished = findall(as[b, :] .== 0) #timepoints at which episode is finished
        #zero out finished steps
        trial_ids[b, finished] .= 0
        trial_ts[b, finished] .= 0
        plan_steps[b, finished] .= 0

        #extract the action number for each iteration
        ep_as = as[b, :]
        for id = 1:(Nrew+1) #for each trial
            inds = findall(trial_ids[b, :] .== id) #indices of this trial
            trial_as = ep_as[inds] #actions within this trial
            anums = zeros(Int64, length(inds)) #list of action numbers
            anum = 1 #start at first action
            for a = 2:length(inds) #go through all network iterations
                anums[a] = anum #store the action number
                if trial_as[a] <= 4.5 anum +=1 end #increment if not a rollout
            end
            trial_anums[b, inds] = anums #store all action numbers
        end
    end

    ## look at performance by trial

    Rmin = 4 #only consider trials with >=Rmin reward (to control for correlation between performance and steps-per-trial)
    inds = findall(sum(rews, dims = 2)[:] .>= Rmin) #episodes with >= Rmin reward
    perfs = reduce(hcat, [[trial_anums[b, trial_ids[b, :] .== t][end] for t = 1:Rmin] for b = inds])' #performance for each trial number

    # compute optimal baseline
    mean_dists = zeros(batch_size) # mean goal distances from all non-goal locations
    for b in 1:batch_size
        dists = dist_to_rew(ps[:, b:b], wall_loc[:, :, b:b], Larena) #goal distances for this arena
        mean_dists[b] = sum(dists) / (Nstates - 1) #average across non-goal states
    end
    μ, s = mean(perfs, dims = 1)[:], std(perfs, dims = 1)[:]/sqrt(batch_size) #compute summary statistics
    data = [Rmin, μ, s, mean(mean_dists)]
    @save "$(datadir)/model_by_trial$seed.bson" data #store data

    ## planning by difficulty

    trials = 15
    new_RTs = zeros(trials, batch_size, hps["T"]) .+ NaN;
    new_alt_RTs = zeros(trials, batch_size, hps["T"]) .+ NaN;
    new_dists = zeros(trials, batch_size) .+ NaN;
    for b = 1:batch_size
        rew = rews[b, :] #rewards in this episode
        min_dists = dist_to_rew(ps[:, b:b], wall_loc[:, :, b:b], Larena) #minimum distances to goal for each state
        for trial = 2:trials
            if sum(rew .> 0.5) .> (trial - 0.5) #finish trial
                inds = findall((trial_ids[b, :] .== trial) .& (trial_ts[b, :] .> 1.5)) #all timepoints within trial

                anums = trial_anums[b, inds]
                RTs = [sum(anums .== anum) for anum = 1:anums[end]]

                plan_nums = plan_steps[b, inds]
                alt_RTs = [sum(plan_nums[anums .== anum]) for anum = 1:anums[end]] #count as number of simulated steps
                new_alt_RTs[trial, b, 1:length(alt_RTs)] = alt_RTs #reaction times

                for anum = 1:anums[end]
                    ainds = findall(anums .== anum)
                    if length(ainds) > 1.5
                        @assert all(plan_nums[ainds[1:(length(ainds)-1)]] .> 0.5) #should all have non-zero plans
                    end
                end

                new_RTs[trial, b, 1:length(RTs)] = RTs #reaction times
                state = states[:, b, inds[1]] #initial state
                new_dists[trial, b] = min_dists[Int(state[1]), Int(state[2])]
            end
        end
    end

    dists = 1:8
    dats = [new_RTs[(new_dists.==dist), :] for dist in dists]
    data = [dists, dats]
    @save "$(datadir)model_RT_by_complexity$(seed)_$epoch.bson" data
    alt_dats = [new_alt_RTs[(new_dists.==dist), :] for dist in dists]
    data = [dists, alt_dats]
    @save "$(datadir)model_RT_by_complexity_bystep$(seed)_$epoch.bson" data

    ## look at exploration

    RTs = zeros(size(rews)) .+ NaN;
    unique_states = zeros(size(rews)) .+ NaN; #how many states had been seen when the action was taken
    for b = 1:batch_size
        inds = findall(trial_ids[b, :] .== 1)
        anums = Int.(trial_anums[b, inds])
        if sum(rews[b, :]) == 0 tmax = sum(as[b, :] .> 0.5) else tmax = findall(rews[b, :] .== 1)[1] end
        visited = Bool.(zeros(16)) #which states have been visited
        for anum = unique(anums)
            state = states[:,b,findall(anums .== anum)[1]]
            visited[Int(state_ind_from_state(Larena, state)[1])] = true
            unique_states[b, anum+1] = sum(visited)
            RTs[b, anum+1] = sum(anums .== anum)
        end
    end

    data = [RTs, unique_states]
    @save "$(datadir)model_unique_states_$(seed)_$epoch.bson" data

    ## do decoding of rew loc by unique states
    unums = 1:15
    dec_perfs = zeros(length(unums))
    for unum = unums
        inds = findall(unique_states .== unum)
        ahot = zeros(Float32, 5, length(inds))
        for (i, ind) = enumerate(inds) ahot[Int(as[ind]), i] = 1f0 end
        X = [hs[:, inds]; ahot] #Nhidden x batch x T -> Nhidden x iters
        Y = rew_locs[:, inds]
        Yhat = m.prediction(X)[17:32, :]
        Yhat = exp.(Yhat .- Flux.logsumexp(Yhat; dims=1)) #softmax over states
        perf = sum(Yhat .* Y) / size(Y, 2)
        dec_perfs[unum] = perf
    end
    data = [unums, dec_perfs]
    @save "$(datadir)model_exploration_predictions_$(seed)_$epoch.bson" data

end
