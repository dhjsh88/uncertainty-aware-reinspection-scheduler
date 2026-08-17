//=============================================================================
// sched_defines.vh - shared constants.
// The 80b record layout is defined only here; all modules use the macros.
//=============================================================================
`ifndef SCHED_DEFINES_VH
`define SCHED_DEFINES_VH

`define N_STREAM    4
`define FIFO_DEPTH  64
`define LATENCY     200
`define CNT_W       32
`define ID_W        8
`define U_W         8

// record = {req_id[79:72], uncertainty[71:64], deadline[63:32], arrival[31:0]}
`define REC_W       (`ID_W + `U_W + `CNT_W + `CNT_W)   // 80
`define REC_ID(x)   x[79:72]
`define REC_U(x)    x[71:64]
`define REC_DL(x)   x[63:32]
`define REC_AR(x)   x[31:0]

`define SLACK_MAX   16'hFFFF

// mode encoding
`define MODE_FIFO   2'd0
`define MODE_EDF    2'd1
`define MODE_UNC    2'd2
`define MODE_HYB    2'd3

`endif
