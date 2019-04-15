# """
# This is a wrapper implementing the change of variable method to simulate the PDMP.
# see https://arxiv.org/abs/1504.06873
# """

"
Function copied from Gillespie.jl and StatsBase

This function is a substitute for `StatsBase.sample(wv::WeightVec)`, which avoids recomputing the sum and size of the weight vector, as well as a type conversion of the propensity vector. It takes the following arguments:
- **w** : an `Array{Float64,1}`, representing propensity function weights.
- **s** : the sum of `w`.
- **n** : the length of `w`.
"
function pfsample(w::Array{Float64,1},s::Float64,n::Int64)
    t = rand() * s
    i = 1
    cw = w[1]
    while cw < t && i < n
        i += 1
        @inbounds cw += w[i]
    end
    return i
end


"""
This is a wrapper implementing the change of variable method to simulate the PDMP.
This wrapper is meant to be called by Sundials.CVode
see https://arxiv.org/abs/1504.06873
"""
function cvode_ode_wrapper(t, x_nv, xdot_nv, user_data)
	# Reminder: user_data = [F R Xd params]
	x    = convert(Vector, x_nv)
	xdot = convert(Vector, xdot_nv)

	# the first x is a dummy variable
	const sr = user_data[2](x, x, user_data[3], t, user_data[4], true)::Float64
	@assert sr > 0.0 "Total rate must be positive"

	const isr = min(1.0e9,1.0 / sr)
	user_data[1](xdot, x, user_data[3], t, user_data[4])
	const ly = length(xdot)
	@inbounds for i = 1:ly
		xdot[i] = xdot[i] * isr
	end
	xdot[end] = isr
	return Sundials.CV_SUCCESS
end

function f_CHV!{T}(F::Function,R::Function,t::Float64, x::Vector{Float64}, xdot::Vector{Float64}, xd::Vector{Int64}, parms::Vector{T})
	# used for the exact method
	# we put [1] to use it in the case of the rejection method as well
	sr = R(xdot,x,xd,t,parms,true)[1]
	@assert sr > 0.0 "Total rate must be positive"
	isr = min(1.0e9,1.0 / sr)
	F(xdot,x,xd,t,parms)
	xdot[end] = 1.0
	ly = length(xdot)
	scale!(xdot, isr)
	nothing
end

"""
This function performs a pdmp simulation using the Change of Variable (CHV) method see https://arxiv.org/abs/1504.06873.
It takes the following arguments:

- **n_max**: an `Int64` representing the maximum number of jumps to be computed.
- **xc0** : a `Vector` of `Float64`, representing the initial states of the continuous variable.
- **xd0** : a `Vector` of `Int64`, representing the initial states of the discrete variable.
- **F!** : an inplace `Function` or a callable type, which itself takes five arguments to represent the vector field; xdot a `Vector` of `Float64` representing the vector field associated to the continuous variable, xc `Vector` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time and parms, a `Vector` of `Float64` representing the parameters of the system.
- **R** : an inplace `Function` or a callable type, which itself takes six arguments to represent the rate functions associated to the jumps;rate `Vector` of `Float64` holding the different reaction rates, xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and sum_rate a `Bool` being a flag asking to return a `Float64` if true and a `Vector` otherwise.
- **DX** : a `Function` or a callable type, which itself takes five arguments to apply the jump to the continuous variable;xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and ind_rec an `Int64` representing the index of the discrete jump.
- **nu** : a `Matrix` of `Int64`, representing the transitions of the system, organised by row.
- **parms** : a `Vector` of `Float64` representing the parameters of the system.
- **tf** : the final simulation time (`Float64`)
- **verbose** : a `Bool` for printing verbose.
- **ode**: ode time stepper :cvode or :lsoda
"""

function chv!{T}(n_max::Int64,xc0::Vector{Float64},xd0::Array{Int64,1},F::Function,R::Function,DX::Function,nu::AbstractArray{Int64},parms::Vector{T},ti::Float64, tf::Float64,verbose::Bool = false;ode=:cvode,ind_save_d=-1:1,ind_save_c=-1:1)
	@assert ode in [:cvode,:lsoda]
	# it is faster to pre-allocate arrays and fill it at run time
	n_max += 1 #to hold initial vector
	nsteps = 1
	npoints = 2 # number of points for ODE integration

	# booleans to know if we save data
	save_c = true
	save_d = true
	# permutation to choose randomly a given number of data Args
	args = pdmpArgs(xc0,xd0,F,R,DX,nu,parms,tf)
	if verbose println("--> Args saved!") end

	# Set up initial variables
	t::Float64 = ti         # initial simulation time
	X0, Xc, Xd, t_hist, xc_hist, xd_hist, res_ode, ind_save_d, ind_save_c = allocate_arrays(ti,xc0,xd0,n_max,ind_save_d=ind_save_d,ind_save_c=ind_save_c)
	nsteps += 1

	deltaxd = copy(nu[1,:]) # declare this variable, variable to hold discrete jump
	numpf   = size(nu,1)    # number of reactions
	rate    = zeros(numpf)  #vector of rates

	# define the ODE flow, this leads to big memory saving
	if ode==:cvode
		Flow=(X0_,Xd_,dt_)->Sundials.cvode(  (tt,x,xdot)->f_CHV!(F,R,tt,x,xdot,Xd_,parms), X0_, [0.0, dt_], abstol = 1e-9, reltol = 1e-7)
	elseif ode==:lsoda
		Flow=(X0_,Xd_,dt_)->LSODA.lsoda((tt,x,xdot,data)->f_CHV!(F,R,tt,x,xdot,Xd_,parms), X0_, [0.0, dt_], abstol = 1e-9, reltol = 1e-7)
	end

	# Main loop
	termination_status = "finaltime"
	while (t < tf) && (nsteps < n_max)

		dt = -log(rand())
		verbose && println("--> t = ",t," - dt = ",dt, ",nstep =  ",nsteps)

		res_ode .= Flow(X0,Xd,dt)

		verbose && println("--> ode solve is done!")

		@inbounds for ii in eachindex(X0)
			X0[ii] = res_ode[end,ii]
		end
		t = res_ode[end,end]

		R(rate,Xc,Xd,t,parms, false)
		# jump time:
		if (t < tf)
			# Update event
			ev = pfsample(rate,sum(rate),numpf)
			deltaxd .= nu[ev,:]
			# Xd = Xd .+ deltaxd
			Base.LinAlg.BLAS.axpy!(1.0, deltaxd, Xd)

			# Xc = Xc .+ deltaxc
			DX(Xc,Xd,t,parms,ev) #requires allocation!!

			verbose && println("--> Which reaction? => ",ev)
			# save state
			t_hist[nsteps] = t
            save_data(nsteps,X0,Xd,xc_hist,xd_hist,ind_save_d, ind_save_c)
		else
			if ode==:cvode
				res_ode .=   Sundials.cvode((tt,x,xdot)->F(xdot,x,Xd,tt,parms), X0[1:end-1], [t_hist[end-1], tf], abstol = 1e-9, reltol = 1e-7)
			elseif ode==:lsoda
				res_ode .= LSODA.lsoda((tt,x,xdot,data)->F(xdot,x,Xd,tt,parms), X0[1:end-1], [t_hist[end-1], tf], abstol = 1e-9, reltol = 1e-7)
			end
			t = tf

			# save state
			t_hist[nsteps] = t
			# xc_hist[:,nsteps] = copy(vec(res_ode[end,:]))
			# xd_hist[:,nsteps] = copy(Xd)
			# save_c && (xc_hist[:,nsteps] .= X0[ind_save_c])
			# save_d && (xd_hist[:,nsteps] .= Xd[ind_save_d])
            save_data(nsteps,X0,Xd,xc_hist,xd_hist,ind_save_d, ind_save_c)
		end
		nsteps += 1
	end
	verbose && println("-->Done")
	stats = pdmpStats(termination_status,nsteps)
	verbose && println("--> xc = ",xd_hist[:,1:nsteps-1])
	return pdmpResult(t_hist[1:nsteps-1],xc_hist[:,1:nsteps-1],xd_hist[:,1:nsteps-1],stats,args)
end


"""
This function performs a pdmp simulation using the Change of Variable (CHV) method, see https://arxiv.org/abs/1504.06873. Its use of Sundials solver is optimized in term of memory consumption. It takes the following arguments:

- **n_max**: an `Int64` representing the maximum number of jumps to be computed.
- **xc0** : a `Vector` of `Float64`, representing the initial states of the continuous variable.
- **xd0** : a `Vector` of `Int64`, representing the initial states of the discrete variable.
- **F** : a `Function` or a callable type, which itself takes five arguments to represent the vector field; xdot a `Vector` of `Float64` representing the vector field associated to the continuous variable, xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time and parms, a `Vector` of `Float64` representing the parameters of the system.
- **R** : a `Function` or a callable type, which itself takes five arguments to represent the rate functions associated to the jumps;xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and sum_rate a `Bool` being a flag asking to return a `Float64` if true and a `Vector` otherwise.
- **Delta** : a `Function` or a callable type, which itself takes five arguments to apply the jump to the continuous variable;xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and ind_rec an `Int64` representing the index of the discrete jump.
- **nu** : a `Matrix` of `Int64`, representing the transitions of the system, organised by row.
- **parms** : a `Vector` of `Float64` representing the parameters of the system.
- **tf** : the final simulation time (`Float64`)
- **verbose** : a `Bool` for printing verbose.
- **ode**: ode time stepper :cvode or :lsoda
"""
function chv_optim!{T}(n_max::Int64,xc0::Vector{Float64},xd0::Array{Int64,1}, F::Base.Callable,R::Base.Callable,DX::Base.Callable,nu::AbstractArray{Int64}, parms::Vector{T},ti::Float64, tf::Float64,verbose::Bool = false;ode=:cvode,ind_save_d=-1:1,ind_save_c=-1:1)
	@assert ode in [:cvode] string("Sorry, ",ode," is not available for chv_optim yet")
	# it is faster to pre-allocate arrays and fill it at run time
	n_max  += 1 #to hold initial vector
	nsteps  = 1
	npoints = 2 # number of points for ODE integration

	# Args
	args = pdmpArgs(xc0,xd0,F,R,DX,nu,parms,tf)
	if verbose println("--> Args saved!") end

	# Set up initial variables
	t::Float64 = ti
	X0, Xc, Xd, t_hist, xc_hist, xd_hist, res_ode, ind_save_d, ind_save_c = allocate_arrays(ti,xc0,xd0,n_max,ind_save_d=ind_save_d,ind_save_c=ind_save_c)
	nsteps += 1

	deltaxd = copy(nu[1,:]) # declare this variable
	numpf   = size(nu,1)    # number of reactions
	rate    = zeros(numpf)#vector of rates
	nsteps += 1

	# Main loop
	termination_status = "finaltime"

	# save ODE context, reduces allocation of memory
	if ode==:cvode
		ctx = cvode_ctx(F,R,Xd,parms, X0, [0.0, 1.0], abstol = 1e-9, reltol = 1e-7)
	else
		# ctx = LSODA.lsoda_context_t()
		dt_lsoda = 0.
	end
	#   prgs = Progress(n_max, 1)
	while (t < tf) && (nsteps<n_max)
		#     update!(prgs, nsteps)
		dt = -log(rand())
		if verbose println("--> t = ",t," - dt = ",dt) end

		if ode==:cvode
			# println(" --> CVODE solve #",nsteps,", X0 = ", X0)
			cvode_evolve!(res_ode, ctx[1],F,R,Xd,parms, X0, [0.0, dt])
			# println(" ----> res_ode = ", res_ode)
			@inbounds for ii in eachindex(X0)
				X0[ii] = res_ode[end,ii]
			end
		else
			@assert 1==0
			if nsteps == 2
				println(" --> LSODA solve #",nsteps,", X0 = ", X0)
				res_ode = LSODA.lsoda((t,x,xdot,data)->f_CHV(F,R,t,x,xdot,Xd,parms), X0, [0.0, dt], abstol = 1e-9, reltol = 1e-7)
				X0 = vec(res_ode[end,:])
				dt_lsoda += dt
				println(" ----> res_ode = ", res_ode, ", neq = ",ctx)
			else
				println(" --> lsoda_evolve #",nsteps,", X0 = ",X0,", res_ode = ",res_ode,",dt = ", [dt_lsoda, dt_lsoda + dt])
				LSODA.lsoda_evolve!(ctx[1], X0, [dt_lsoda, dt_lsoda + dt])
				dt_lsoda += dt
			end
		end
		if verbose println(" --> ode solve is done!") end

		R(rate,Xc,Xd,t,parms, false)

		# Update time
		t = X0[end] #t = res_ode[end,end]
		# @assert t == X0[end]
		# Update event
		if (t < tf)
			ev = pfsample(rate,sum(rate),numpf)
			deltaxd .= nu[ev,:]
			# Xd = Xd .+ deltaxd
			Base.LinAlg.BLAS.axpy!(1.0, deltaxd, Xd)

			# Xc = Xc .+ deltaxc
			DX(Xc,Xd,t,parms,ev) #requires allocation!!

			if verbose println(" --> Which reaction? => ",ev) end

			# save state
			t_hist[nsteps] = t

			# copy cols: faster, cf. performance tips in JuliaLang
            save_data(nsteps,X0,Xd,xc_hist,xd_hist,ind_save_d, ind_save_c)
		else
			if ode==:cvode
				res_ode = Sundials.cvode((t,x,xdot)->F(xdot,x,Xd ,t,parms), X0[1:end-1], [t_hist[end-1], tf], abstol = 1e-8, reltol = 1e-7)
			end
			t = tf

			# save state
			t_hist[nsteps] = t
            save_data(nsteps,X0,Xd,xc_hist,xd_hist,ind_save_d, ind_save_c)
		end
		nsteps += 1
	end

	if ode==:cvode
		# Sundials.CVodeFree(Ref([ctx]))
		Sundials.empty!(ctx[1])
		Sundials.empty!(ctx[2])
		Sundials.empty!(ctx[3])
	end
	# collect the data
	if verbose println("-->Done") end
	stats = pdmpStats(termination_status,nsteps)
	if verbose println("--> xc = ",xd_hist[:,1:nsteps-1]) end
	if verbose println("--> time = ",t_hist[1:nsteps-1]) end
	if verbose println("--> chv_optim, #jumps = ",length(t_hist[1:nsteps-1])) end
	result = pdmpResult(t_hist[1:nsteps-1],xc_hist[:,1:nsteps-1],xd_hist[:,1:nsteps-1],stats,args)
	return(result)
end
