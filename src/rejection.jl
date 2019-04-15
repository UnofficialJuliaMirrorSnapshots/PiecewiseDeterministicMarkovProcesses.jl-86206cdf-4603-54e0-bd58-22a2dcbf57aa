"""
This function performs a simulation using the rejection method.
It takes the following arguments:

- **n_max**: an `Int64` representing the maximum number of jumps to be computed.
- **xc0** : a `Vector` of `Float64`, representing the initial states of the continuous variable.
- **xd0** : a `Vector` of `Int64`, representing the initial states of the discrete variable.
- **F** : a `Function` or a callable type, which itself takes five arguments to represent the vector field; xdot a `Vector` of `Float64` representing the vector field associated to the continuous variable, xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time and parms, a `Vector` of `Float64` representing the parameters of the system.
- **R!** : a `Function` or a callable type, which itself takes five arguments to represent the rate functions associated to the jumps;xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and sum_rate a `Bool` being a flag asking to return a `Float64` if true and a `Vector` otherwise. The returned vector has components. If sum_rate is `False`, one must return rate_vector, bound_ where bound_ is a bound on the total rate vector. In the case sum_rate is `True`, one must return total_rate,bound_ where total_rate is a `Float64` that is the sum of the rates. `R!(rate,xc,xd,t,parms,sum_rate)` returns `Float64,Float64`. In case `sum_rate = true`, you are not allowed to modify the first argument e.g. `rate`
- **Delta** : a `Function` or a callable type, which itself takes five arguments to apply the jump to the continuous variable;xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and ind_rec an `Int64` representing the index of the discrete jump.
- **nu** : a `Matrix` of `Int64`, representing the transitions of the system, organised by row.
- **parms** : data for the parameters of the system.
- **tf** : the final simulation time (`Float64`)
- **verbose** : a `Bool` for printing verbose.
- **ode**: ode time stepper :cvode or :lsoda
"""
function rejection!(n_max::Int64,xc0::AbstractVector{Float64},xd0::AbstractVector{Int64},F::Function,R::Function,DX::Function,nu::AbstractArray{Int64},parms,ti::Float64, tf::Float64,verbose::Bool = false;ode = :cvode,save_rejected=false,ind_save_d=-1:1,ind_save_c=-1:1)
	@assert ode in [:cvode,:lsoda]
	verbose && printstyled(color=:red,"--> Start rejection method\n")

	# define the ODE flow
	if ode == :cvode
		Flow = (X0_,Xd_,tp_)->Sundials.cvode(  (tt,x,xdot)->F(xdot,x,Xd,tt,parms), X0_, tp_, abstol = 1e-9, reltol = 1e-7)
	elseif ode == :lsoda
		Flow = (X0_,Xd_,tp_)->LSODA.lsoda((tt,x,xdot,data)->F(xdot,x,Xd,tt,parms), X0_, tp_, abstol = 1e-9, reltol = 1e-7)
	end

	# it is faster to pre-allocate arrays and fill it at run time
	n_max  += 1 #to hold initial vector
	nsteps  = 1
	npoints = 2 # number of points for ODE integration

	# Set up initial variables
	t = ti
	X0,_, Xd, t_hist, xc_hist, xd_hist, res_ode = allocate_arrays(ti,xc0,xd0,n_max,true)

	deltaxd = copy(nu[1,:]) # declare this variable
	numpf   = size(nu,1)    # number of reactions
	rate    = zeros(numpf)  # vector of rates
	tp = [ti, tf]           # vector to hold the time interval over which to integrate the flow

	#variables for rejection algorithm
	reject = true
	lambda_star = 0.0 # this is the bound for the rejection method
	ppf = R(rate,X0,Xd,t,parms,true)

	# @assert ppf[2] == R(rate,X0+0.1265987*cumsum(ones(length(X0))),Xd,t+0.124686489,parms,true)[2] "Your rejection bound must be constant in between jumps, it cannot depend on time!!"
	# rate *= 0;ppf = R(rate,X0,Xd,t,parms,true)
	# @assert sum(rate) == 0 "You cannot modify the first argument of your rate function when sum_rate = true"

	while (t < tf) && (nsteps < n_max)
		if verbose println("--> step : ",nsteps," / ",n_max ) end
		reject = true
		while (reject) && (nsteps < n_max)
			tp .= [t, min(tf, t - log(rand())/ppf[2]) ] #mettre un lambda_star?
			res_ode .= Flow(X0,Xd,tp)

			@inbounds for ii in eachindex(X0)
				X0[ii] = res_ode[end,ii]
			end
			verbose && println("----> t∈",tp,", dt = ",tp[2]-tp[1],", xc = ",X0 )

			t = tp[end]
			ppf = R(rate,X0,Xd,t,parms,true)
			@assert ppf[1] <= ppf[2] "(Rejection algorithm) Your bound on the total rate is wrong, $ppf"
			if t == tf
				reject = false
			else
				reject = rand() < (1 - ppf[1] / ppf[2])
			end
		end

		# there is a jump!
		ppf = R(rate,X0,Xd,t,parms,false)

		if (t < tf)
			verbose && println("----> Jump!, ratio = ",ppf[1]/ppf[2])
			# make a jump
			ev = pfsample(rate,sum(rate),numpf)
			deltaxd .= nu[ev,:]

			# Xd = Xd .+ deltaxd
			LinearAlgebra.BLAS.axpy!(1.0, deltaxd, Xd)

			# Xc = Xc .+ deltaxc
			DX(X0,Xd,X0[end],parms,ev)
		end

		nsteps += 1
		t_hist[nsteps] = t
        @inbounds for ii in eachindex(X0)
			xc_hist[ii,nsteps] = X0[ii]
        end
        @inbounds for ii in eachindex(Xd)
			xd_hist[ii,nsteps] = Xd[ii]
        end
	end
	if verbose println("-->Done") end
	if verbose println("--> xd = ",xd_hist[:,1:nsteps]) end
	result = PDMPResult(t_hist[1:nsteps],xc_hist[:,1:nsteps],xd_hist[:,1:nsteps],Float64[])
	return(result)
end

"""

rejection_exact

This function performs a simulation using the rejection method when the flow **is known analytically**.
It takes the following arguments:

- **n_max**: an `Int64` representing the maximum number of jumps to be computed.
- **xc0** : a `Vector` of `Float64`, representing the initial states of the continuous variable.
- **xd0** : a `Vector` of `Int64`, representing the initial states of the discrete variable.
- **Phi!** : a `Function` or a callable type, which itself takes 6 arguments to represent the vector field; rate a `Vector` of `Float64` representing the **flow** of the vector which needs to be filled with values of the rates, xdot a `Vector` of `Float64` representing the vector field associated to the continuous variable, xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time and parms, a `Vector` of `Float64` representing the parameters of the system, sum_of_rate a `Bool` stating if the function must return the total rate.
- **R!** : a `Function` or a callable type, which itself takes five arguments to represent the rate functions associated to the jumps;xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and sum_rate a `Bool` being a flag asking to return a `Float64` if true and a `Vector` otherwise. The returned vector has components. If sum_rate is `False`, one must return rate_vector, bound_ where bound_ is a bound on the total rate vector. In the case sum_rate is `True`, one must return total_rate,bound_ where total_rate is a `Float64` that is the sum of the rates. In any case, the function must return a couple (total_rates, bound) where bound is a bound for the total rate.
- **Delta** : a `Function` or a callable type, which itself takes five arguments to apply the jump to the continuous variable;xc `Vector` of `Float64` representing the current state of the continuous variable, xd `Vector` of `Int64` representing the current state of the discrete variable, t a `Float64` representing the current time, parms a `Vector` of `Float64` representing the parameters of the system and ind_rec an `Int64` representing the index of the discrete jump.
- **nu** : a `Matrix` of `Int64`, representing the transitions of the system, organised by row.
- **parms** : data for the parameters of the system.
- **tf** : the final simulation time (`Float64`)
- **verbose** : a `Bool` for printing verbose.
"""
function rejection_exact(n_max::Int64,xc0::AbstractVector{Float64},xd0::AbstractVector{Int64},Phi::Function,R::Function,DX::Function,nu::AbstractArray{Int64},parms,ti::Float64, tf::Float64,verbose::Bool = false, xd_jump::Bool=true;ind_save_d=-1:1,ind_save_c=-1:1)
	# it is faster to pre-allocate arrays and fill it at run time
	n_max += 1 #to hold initial vector
	nsteps = 1
	npoints = 2 # number of points for ODE integration
	njumps = 1



	# Set up initial variables
	t::Float64 = ti
	X0, _, Xd, t_hist, xc_hist, xd_hist, res_ode = allocate_arrays(ti,xc0,xd0,n_max,true)

	deltaxd     = copy(nu[1,:]) # declare this variable
	numpf       = size(nu,1)    # number of reactions
	rate_vector = zeros(numpf)#vector of rates
	tp = [0., 1.]

	reject = true
	nb_rejet = 0
	lambda_star = 0.0 # this is the bound for the rejection method
	tp = [0.,0.]
	lambda_star = R(rate_vector,X0,Xd,t,parms,true)[2]

	@assert lambda_star == R(rate_vector,X0,Xd,t+rand(),parms,true)[2] "Your rejection bound must be constant in between jumps, it cannot depend on time!!"

	t_hist[njumps] = t
	xc_hist[:,njumps] = copy(X0[1:end])
	xd_hist[:,njumps] = copy(Xd)


	while (t < tf) && (njumps < n_max)
		if verbose println("--> step : $njumps, / $n_max, #reject = $nsteps" ) end
		reject = true
		nsteps = 1
		while (reject) && (nsteps < 10^6) && (t < tf)
			tp = [t, t - log(rand())/lambda_star ]		# mettre un lambda_star?
			Phi(res_ode, X0, Xd, tp, parms) 				# we evolve the flow inplace
			X0 = vec(res_ode[end,:])
			t = tp[end]
			ppf = R(rate_vector, X0, Xd, t, parms, true) 	# we don't want the full rate vector, just the sum of rates
			@assert ppf[1] <= ppf[2] "(Rejection algorithm) Your bound on the total rate is wrong"
			reject = rand() <  (1. - ppf[1] / ppf[2])
			nsteps += 1
		end
		# keep track of nb of rejections
		nb_rejet += nsteps

		@assert(nsteps <= 10^6,"Error, too many rejections!!")
		njumps += 1
		t_hist[njumps] = t
		xc_hist[:,njumps] = copy(X0[1:end])
		xd_hist[:,njumps] = copy(Xd)
		# there is a jump!
		lambda_star = R(rate_vector,X0,Xd,t,parms,false)[2]
		if verbose println("----> rate = $rate_vector" ) end

		if (t < tf)
			# make a jump
			ev = pfsample(rate_vector,sum(rate_vector),numpf)
			if verbose println("----> reaction = $ev" ) end

			if xd_jump
				deltaxd = nu[ev,:]
				if verbose println("----> delta = $deltaxd" ) end
				# Xd = Xd .+ deltaxd
				LinearAlgebra.BLAS.axpy!(1.0, deltaxd, Xd)
			end
			# Xc = Xc .+ deltaxc
			DX(X0,Xd,t,parms,ev)
		end
	end
	println("njumps = ",njumps," / rejections = ", nb_rejet)
	if verbose println("-->Done") end

	# if verbose println("--> xc = ",xd_hist[:,1:nsteps]) end
	result = PDMPResult(t_hist[1:njumps],xc_hist[:,1:njumps],xd_hist[:,1:njumps],Float64[])
	return(result)
end


rejection_exact(n_max::Int64,xd0::AbstractVector{Int64},R::Base.Callable,nu,parms,ti::Float64, tf::Float64,verbose::Bool = false, xd_jump::Bool=true) = PDMP.rejection_exact(n_max,[0.],xd0,Phi_dummy,R,Delta_dummy,nu,parms,ti, tf,verbose, xd_jump)
