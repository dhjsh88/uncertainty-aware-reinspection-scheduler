//=============================================================================
// req_fifo.v - FWFT (first-word fall-through) sync FIFO.
//   Memory array plus a registered head slot: the head is cached in a
//   register so policy_core can read it combinationally, hiding the 1-cycle
//   memory read latency. Same-cycle push+pop supported.
//   capacity = DEPTH (mem) + 1 (head).
//=============================================================================
`include "sched_defines.vh"

module req_fifo #(
    parameter DEPTH = `FIFO_DEPTH,
    parameter DW    = `REC_W,
    parameter AW    = $clog2(`FIFO_DEPTH)
)(
    input  wire            i_clk,
    input  wire            i_rstn,
    input  wire            i_clr,
    input  wire            i_push,
    input  wire [DW-1:0]   i_wdata,
    input  wire            i_pop,
    output reg  [DW-1:0]   o_head,       // FWFT: valid data visible same cycle
    output reg             o_head_vld,
    output wire            o_full,
    output wire [AW:0]     o_cnt         // mem + head
);

    reg [DW-1:0] mem [0:DEPTH-1];
    reg [AW-1:0] r_wptr, r_rptr;
    reg [AW:0]   r_icnt;                  // mem occupancy only

    wire w_iempty = (r_icnt == {(AW+1){1'b0}});
    wire w_ifull  = (r_icnt == DEPTH[AW:0]);

    // FWFT control
    wire w_fill = (~o_head_vld | i_pop) & ~w_iempty;          // mem -> head
    wire w_thru = (~o_head_vld | i_pop) & w_iempty & i_push;  // push -> head direct
    wire w_wr   = i_push & ~w_thru & ~w_ifull;                // push -> mem

    // mem write
    always @(posedge i_clk) begin
        if (w_wr) mem[r_wptr] <= i_wdata;
    end

    // pointers / count
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_wptr <= {AW{1'b0}}; r_rptr <= {AW{1'b0}}; r_icnt <= {(AW+1){1'b0}};
        end else if (i_clr) begin
            r_wptr <= {AW{1'b0}}; r_rptr <= {AW{1'b0}}; r_icnt <= {(AW+1){1'b0}};
        end else begin
            if (w_wr)   r_wptr <= r_wptr + 1'b1;
            if (w_fill) r_rptr <= r_rptr + 1'b1;
            case ({w_wr, w_fill})
                2'b10   : r_icnt <= r_icnt + 1'b1;   // write only
                2'b01   : r_icnt <= r_icnt - 1'b1;   // fill only
                default : ;                           // both or neither
            endcase
        end
    end

    // head register
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn)      o_head_vld <= 1'b0;
        else if (i_clr)   o_head_vld <= 1'b0;
        else begin
            if (w_thru) begin
                o_head     <= i_wdata;
                o_head_vld <= 1'b1;
            end else if (w_fill) begin
                o_head     <= mem[r_rptr];
                o_head_vld <= 1'b1;
            end else if (i_pop) begin
                o_head_vld <= 1'b0;
            end
        end
    end

    assign o_cnt  = r_icnt + {{AW{1'b0}}, o_head_vld};
    assign o_full = w_ifull & o_head_vld;

endmodule
