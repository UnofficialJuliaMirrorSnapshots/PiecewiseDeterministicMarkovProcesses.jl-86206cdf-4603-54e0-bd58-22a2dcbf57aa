using PiecewiseDeterministicMarkovProcesses, LinearAlgebra, Random

function F_tcpf(xcdot, xc, xd, t, parms::Vector{Float64})
  # vector field used for the continuous variable
  if mod(xd[1],2)==0
    xcdot[1] = xc[1]
  else
    xcdot[1] = -xc[1]
  end
  nothing
end

function R_tcpf(xc, xd, t::Float64, parms, sum_rate::Bool)
  # fonction de tau
  if sum_rate==false
    return vec([5.0/(1.0 + exp(-xc[1]/1.0 + 5.0)) + 0.1, parms[1]])
  else
    return 5.0/(1.0 + exp(-xc[1]/1.0 + 5.0)) + 0.1 + parms[1]
  end
end

xc0 = vec([0.05])
xd0 = vec([0, 1])

const nu_tcpf = [[1 0];[0 -1]]
parms = vec([0.1]) # sampling rate
tf = 250.

println("--> Case chv:")
  dummy_f =  PiecewiseDeterministicMarkovProcesses.pdmp!(2,xc0,xd0,F_tcpf,R_tcpf,nu_tcpf,parms,0.0,tf,ode=:cvode)
  Random.seed!(1234)
  dummy_f =  @time PiecewiseDeterministicMarkovProcesses.pdmp!(200,xc0,xd0,F_tcpf,R_tcpf,nu_tcpf,parms,0.0,tf,ode=:cvode)
  println("--> Case optimised:")
  dummy_t =  PiecewiseDeterministicMarkovProcesses.pdmp!(2,xc0,xd0,F_tcpf,R_tcpf,nu_tcpf,parms,0.0,tf, algo=:chv_optim)
  Random.seed!(1234)
  dummy_t =  @time PiecewiseDeterministicMarkovProcesses.pdmp!(200,xc0,xd0,F_tcpf,R_tcpf,nu_tcpf,parms,0.0,tf, algo=:chv_optim)

println("For simulations:")
Random.seed!(1234)
tf = 250.
parms[1] = 10.0
result = @time PiecewiseDeterministicMarkovProcesses.sample!(200,xc0,xd0,F_tcpf,R_tcpf,nu_tcpf,parms,0.0,tf, algo=:chv_optim)
println("#jumps = ", length(result.time))
