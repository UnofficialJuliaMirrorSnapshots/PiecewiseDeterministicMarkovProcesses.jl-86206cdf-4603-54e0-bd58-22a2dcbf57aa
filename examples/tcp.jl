# using Revise
using PiecewiseDeterministicMarkovProcesses, LinearAlgebra, Random, DifferentialEquations, Sundials

function AnalyticalSample(xc0,xd0,ti,nj::Int64)
	xch = [xc0[1]]
	xdh = [xd0[1]]
	th  = [ti]
	t = ti
	while length(th)<nj
		xc = xch[end]
		xd = xdh[end]
		S = -log(rand())
		a = mod(xd[1],2)==0 ? -1 : 1
		dt = (exp(a*S)-1)*exp(-a*S)/(a*xc)
		t += dt
		push!(th, t)
		push!(xch,xc * exp(a*S) )
		push!(xdh,xd .+ 1 )
		S = -log(rand())
	end
	return th,xch,xdh
end

function F_tcp!(ẋ, xc, xd, t, parms)
	# vector field used for the continuous variable
	if mod(xd[1],2)==0
		 ẋ[1] = 1.
	else
		 ẋ[1] = -1.
	end
	nothing
end

rate_tcp(x) = 1/x

function R_tcp!(rate, xc, xd, t, parms, sum_rate::Bool)
	if sum_rate==false
		rate[1] = rate_tcp(xc[1])
		rate[2] = 0.0
		return 0., 100.
	else
		return rate_tcp(xc[1]), 100.
	end
end

xc0 = [ 1.0 ]
xd0 = [0, 1]

nu_tcp = [[1 0];[0 -1]]
parms = [0.0]
tf = 100000.
nj = 100

Random.seed!(1234)
	res_a = AnalyticalSample(xc0,xd0,0.,nj)

errors = Float64[]

println("\n\nComparison of solvers")
	for ode in [(:cvode,"cvode"),(:lsoda,"lsoda"),(CVODE_BDF(),"CVODEBDF"),(CVODE_Adams(),"CVODEAdams"),(Rosenbrock23(),"RS23"),(Tsit5(),"tsit5"),(Rodas4P(autodiff=false),"rodas4P-noAutoDiff"),(Rodas5(),"rodas5"),(AutoTsit5(Rosenbrock23()),"AutoTsit5RS23")]
	Random.seed!(1234)
	res =  @time PiecewiseDeterministicMarkovProcesses.pdmp!(xc0, xd0, F_tcp!, R_tcp!, nu_tcp, parms, 0.0, tf, n_jumps = nj,   ode = ode[1])
	printstyled(color=:green,"--> norm difference = ", norm(res.time - res_a[1],Inf64), "  - solver = ",ode[2],"\n\n")
	push!(errors,norm(res.time - res_a[1],Inf64))
end



Random.seed!(1234)
	res =  @time PiecewiseDeterministicMarkovProcesses.pdmp!(xc0, xd0, F_tcp!, R_tcp!, nu_tcp, parms, 0.0, tf, n_jumps = nj,   ode = Tsit5(), save_positions = (false, false))

# plot(res_a[1],res_a[2])
# plot!(res.time,res.xc[:,1])
# #
# # case with no allocations  0.000719 seconds (672 allocations: 57.250 KiB)
# Random.seed!(1234)
#	 res =  @time PiecewiseDeterministicMarkovProcesses.pdmp!(xc0, xd0, F_tcp!, R_tcp!, nu_tcp, parms, 0.0, tf, n_jumps = nj,   ode =Tsit5())
#
# # case with no allocations  0.000719 seconds (675 allocations: 57.297 KiB)
# Random.seed!(1234)
#	 res =  @time PiecewiseDeterministicMarkovProcesses.pdmp!(xc0, xd0, F_tcp!, R_tcp!, nu_tcp, parms, 0.0, tf, n_jumps = nj,   ode =Tsit5())
#	 res.time[1:10] |> println
#
# # Random.seed!(1234)
# #	 using PiecewiseDeterministicMarkovProcesses
# #	 println("\n"*"+"^40)
# #	 res =  @time PiecewiseDeterministicMarkovProcesses.pdmp!(xc0, xd0, F_tcp!, R_tcp!, nu_tcp, parms, 0.0, tf, n_jumps = 10,   ode =Tsit5(), algo=:rejection, verbose=true)
# #
# #	 res.time |> println
