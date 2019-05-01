using Revise, PiecewiseDeterministicMarkovProcesses, LinearAlgebra, Random, DifferentialEquations, Sundials
const PDMPP = PiecewiseDeterministicMarkovProcesses

function F_fd!(ẋ, xc, xd, t, parms)
    # vector field used for the continuous variable
    if mod(xd[1],2)==0
        ẋ[1] = 1 + xd[1] + 0
    else
        ẋ[1] = -xc[1]
    end
    nothing
end

rate_tcp(x) = 1/x

function R_fd!(rate, xc, xd, t, parms, sum_rate::Bool)
    rate[1] = 1.0 + rate_tcp(xd[1]) * xc[1]
    if sum_rate==false
        return 0., 0.
    else
        return sum(rate), 0.
    end
end

Dummy! = PDMP.Delta_dummy

xc0 = [ 1.0 ]
xd0 = [ 1  ]

nu_fd = [[1 0];[0 -1]]
parms = [0.0]

# works:
Random.seed!(12)
    res =  @time PDMP.chv_diffeq!(xc0, xd0, F_fd!, R_fd!,Dummy!, nu_fd, parms, 0.0, 10.0,false; n_jumps = 30,   ode = CVODE_BDF());

Random.seed!(12)
    res =  @time PDMP.chv_diffeq!(xc0, Int.(xd0), F_fd!, R_fd!,Dummy!, Int.(nu_fd), parms, 0.0, 10.0,false; n_jumps = 30,   ode = Tsit5(),save_positions=(false,false))



# fail because of autodiff
Random.seed!(12)
    res =  @time PDMP.chv_diffeq!(xc0, (xd0), F_fd!, R_fd!,Dummy!, (nu_fd), parms, 0.0, 10.0,false; n_jumps = 30, ode = AutoTsit5(Rosenbrock23(autodiff=true)),save_positions=(false,false))



# using StaticArrays
# sxc0 = @MVector [ 1.0 ]
# sxd0 = @MVector [1, 1]
# res =  @time PDMP.chv_diffeq!(sxc0, sxd0, F_fd!, R_fd!,Dummy!, Int.(nu_fd), parms, 0.0, 10.0,false; n_jumps = 30,   ode = Tsit5(),save_positions=(false,false))