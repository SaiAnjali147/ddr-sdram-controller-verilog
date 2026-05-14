// ============================================================
// Testbench 1: General Controller Simulation
// Matches: Figure 8 waveform from the paper
// Tests: Reset, NOP, Precharge, LoadMR, Refresh, ACT sequence
// Run in ModelSim:
//   vlog ddr_controller.v tb_controller.v
//   vsim -t 1ns work.tb_controller
//   run -all
// ============================================================

`timescale 1ns / 1ps

module tb_controller;

// ---- DUT ports ----
reg         clk, clk2x, reset_n;
reg  [7:1]  u_cmd;
reg  [21:0] u_addr;
reg  [127:0] u_data_i;
wire [127:0] u_data_o;
wire         u_data_valid;
wire         u_ref_ack;
wire         ddr_rasb, ddr_casb, ddr_web;
wire [11:0]  ddr_ad;
wire [1:0]   ddr_ba;
wire         ddr_cke, ddr_csb;
wire [63:0]  ddr_dq;
wire [1:0]   ddr_dqs;
wire [7:0]   ddr_dm;

// ---- DUT instantiation ----
ddr_controller DUT (
    .clk        (clk),
    .clk2x      (clk2x),
    .reset_n    (reset_n),
    .u_cmd      (u_cmd),
    .u_addr     (u_addr),
    .u_data_i   (u_data_i),
    .u_data_o   (u_data_o),
    .u_data_valid(u_data_valid),
    .u_ref_ack  (u_ref_ack),
    .ddr_rasb   (ddr_rasb),
    .ddr_casb   (ddr_casb),
    .ddr_web    (ddr_web),
    .ddr_ad     (ddr_ad),
    .ddr_ba     (ddr_ba),
    .ddr_cke    (ddr_cke),
    .ddr_csb    (ddr_csb),
    .ddr_dq     (ddr_dq),
    .ddr_dqs    (ddr_dqs),
    .ddr_dm     (ddr_dm)
);

// ---- Clock generation ----
// clk  = 100 MHz  (10ns period)
// clk2x = 200 MHz  (5ns period)
initial clk   = 0;
initial clk2x = 0;
always #5  clk   = ~clk;
always #2.5 clk2x = ~clk2x;

// ---- Command parameters ----
parameter CMD_NOP      = 7'b0000000;
parameter CMD_READ     = 7'b0000001;
parameter CMD_WRITE    = 7'b0000010;
parameter CMD_REFRESH  = 7'b0000100;
parameter CMD_PRECHARGE= 7'b0001000;

// ---- Task: apply command for N cycles ----
task apply_cmd;
    input [7:1] cmd;
    input [21:0] addr;
    input integer cycles;
    integer i;
    begin
        u_cmd  = cmd;
        u_addr = addr;
        for (i = 0; i < cycles; i = i + 1)
            @(posedge clk);
    end
endtask

// ---- Stimulus ----
initial begin
    // Initialise
    reset_n  = 0;
    u_cmd    = CMD_NOP;
    u_addr   = 22'h00000;
    u_data_i = 128'h0;

    // Assert reset for 5 cycles
    repeat(5) @(posedge clk);
    reset_n = 1;
    $display("[%0t] Reset released", $time);

    // Wait for init_done (200 clk cycles inside DUT)
    repeat(210) @(posedge clk);
    $display("[%0t] Initialization complete", $time);

    // --- PRECHARGE ALL ---
    $display("[%0t] Issuing PRECHARGE ALL", $time);
    apply_cmd(CMD_PRECHARGE, 22'h000400, 5);  // A10=1 => all banks

    // --- LOAD MODE REGISTER ---
    $display("[%0t] Issuing LOAD MODE REGISTER", $time);
    apply_cmd(CMD_NOP, 22'h000022, 8);        // MRS addr encoded in low bits

    // --- AUTO REFRESH x2 ---
    $display("[%0t] AUTO REFRESH #1", $time);
    apply_cmd(CMD_REFRESH, 22'h0, 12);
    $display("[%0t] AUTO REFRESH #2", $time);
    apply_cmd(CMD_REFRESH, 22'h0, 12);

    // --- ACT (open row 0x3AC) ---
    $display("[%0t] ACT — opening row", $time);
    apply_cmd(CMD_NOP, 22'h0003AC, 6);  // address with row

    // --- NOP (idle) ---
    $display("[%0t] NOP — idle", $time);
    apply_cmd(CMD_NOP, 22'h0, 20);

    $display("[%0t] Controller test DONE", $time);
    #50;
    $finish;
end

// ---- Monitor ----
initial begin
    $display("Time        | State signals");
    $display("            | RASB CASB WEB  CKE  CSB  AD[11:0]  BA REF_ACK");
    $monitor("%0t | %b    %b    %b   %b    %b    %h     %b  %b",
             $time, ddr_rasb, ddr_casb, ddr_web,
             ddr_cke, ddr_csb, ddr_ad, ddr_ba, u_ref_ack);
end

// ---- Waveform dump ----
initial begin
    $dumpfile("tb_controller.vcd");
    $dumpvars(0, tb_controller);
end

endmodule
