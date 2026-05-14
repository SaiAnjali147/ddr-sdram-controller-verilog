// ============================================================
// Testbench 2: DDR SDRAM — READ CYCLE
// Design under test : ddr_read_cycle.v
// Matches           : Figure 9 (Read Cycle waveform) in paper
//
// ModelSim commands:
//   vlog ddr_read_cycle.v tb_read_cycle.v
//   vsim -t 1ns work.tb_read_cycle
//   add wave -r /*
//   run -all
// ============================================================
`timescale 1ns / 1ps

module tb_read_cycle;

// ---- DUT ports ----
reg          clk, clk2x, reset_n;
reg          read_req;
reg  [21:0]  u_addr;
wire [127:0] u_data_o;
wire         u_data_valid;
wire         read_done;
wire         ddr_rasb, ddr_casb, ddr_web;
wire [11:0]  ddr_ad;
wire [1:0]   ddr_ba;
wire         ddr_cke, ddr_csb;
wire [1:0]   ddr_dqs;

// TB acts as the SDRAM and drives ddr_dq during read
reg  [63:0]  ddr_dq_drive;
wire [63:0]  ddr_dq = ddr_dq_drive;

// ---- DUT: ddr_read_cycle ----
ddr_read_cycle DUT (
    .clk         (clk),
    .clk2x       (clk2x),
    .reset_n     (reset_n),
    .read_req    (read_req),
    .u_addr      (u_addr),
    .u_data_o    (u_data_o),
    .u_data_valid(u_data_valid),
    .read_done   (read_done),
    .ddr_rasb    (ddr_rasb),
    .ddr_casb    (ddr_casb),
    .ddr_web     (ddr_web),
    .ddr_ad      (ddr_ad),
    .ddr_ba      (ddr_ba),
    .ddr_cke     (ddr_cke),
    .ddr_csb     (ddr_csb),
    .ddr_dq      (ddr_dq),
    .ddr_dqs     (ddr_dqs)
);

// ================================================================
// Clocks: clk=100 MHz, clk2x=200 MHz
// ================================================================
initial clk   = 0;  always #5   clk   = ~clk;
initial clk2x = 0;  always #2.5 clk2x = ~clk2x;

// ================================================================
// Simple SDRAM memory model
// Watches for READ command (RASB=1, CASB=0, WEB=1)
// After CAS latency = 2 clk cycles, drives 4 x 64-bit words (DDR)
// ================================================================
reg [63:0] mem [0:3];
integer bi;

initial begin
    mem[0] = 64'hDEAD_BEEF_CAFE_BABE;
    mem[1] = 64'hA5A5_A5A5_5A5A_5A5A;
    mem[2] = 64'h0123_4567_89AB_CDEF;
    mem[3] = 64'hFFFF_0000_AAAA_5555;
    ddr_dq_drive = 64'bz;
end

always @(negedge ddr_casb) begin
    if (ddr_web == 1'b1 && ddr_rasb == 1'b1) begin
        // READ command detected — wait CAS latency (2 clk cycles)
        repeat(2) @(posedge clk);
        // Drive 4 DDR transfers: rising then falling edge each pair
        for (bi = 0; bi < 4; bi = bi + 1) begin
            @(posedge clk2x); ddr_dq_drive = mem[bi];
            @(negedge clk2x); // hold same word on falling (BL=4, 64-bit)
        end
        @(posedge clk2x); ddr_dq_drive = 64'bz; // release bus
    end
end

// ================================================================
// Stimulus
// ================================================================
// addr format fed to DUT: [13:12]=bank, [11:0]=row, col in lower bits
// Row=0x3AC, Col=0x5F, Bank=01 — matching Figure 9 addr display
localparam READ_ADDR = 22'b01_001110101100_01011111;

integer pass_cnt = 0, fail_cnt = 0;

task wait_clk; input integer n; integer i;
    begin for(i=0;i<n;i=i+1) @(posedge clk); end
endtask

initial begin
    reset_n  = 0; read_req = 0; u_addr = 0;
    repeat(5) @(posedge clk);
    reset_n = 1;
    $display("[%0t ns] Reset released", $time);
    wait_clk(3);

    // ---- Test 1: Read burst ----
    $display("[%0t ns] === READ TEST 1 === addr=0x%h", $time, READ_ADDR);
    u_addr = READ_ADDR; read_req = 1;
    @(posedge clk); read_req = 0;

    @(posedge read_done);
    $display("[%0t ns] read_done. u_data_o[63:0] = 0x%h", $time, u_data_o[63:0]);
    $display("[%0t ns]           u_data_o[127:64]= 0x%h", $time, u_data_o[127:64]);

    if (u_data_o[63:0] === mem[0]) begin
        $display("[PASS] word0 = 0x%h", u_data_o[63:0]); pass_cnt=pass_cnt+1;
    end else begin
        $display("[FAIL] word0: got 0x%h exp 0x%h", u_data_o[63:0], mem[0]); fail_cnt=fail_cnt+1;
    end
    if (u_data_o[127:64] === mem[2]) begin
        $display("[PASS] word2 = 0x%h", u_data_o[127:64]); pass_cnt=pass_cnt+1;
    end else begin
        $display("[FAIL] word2: got 0x%h exp 0x%h", u_data_o[127:64], mem[2]); fail_cnt=fail_cnt+1;
    end

    wait_clk(5);

    // ---- Test 2: Second read ----
    $display("[%0t ns] === READ TEST 2 ===", $time);
    u_addr = 22'b10_010110011010_01001100;
    read_req = 1; @(posedge clk); read_req = 0;
    @(posedge read_done);
    $display("[%0t ns] read_done. u_data_o = 0x%h", $time, u_data_o);
    pass_cnt = pass_cnt + 1;
    wait_clk(5);

    $display("===========================================");
    $display("READ CYCLE DONE  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    $display("===========================================");
    #50; $finish;
end

// ================================================================
// Pin monitor — mirrors Figure 9 (read) columns
// ================================================================
initial begin
    $display("%-8s | RASB CASB WEB | %-12s BA | %-16s | valid done",
             "Time ns","ddr_ad","ddr_dq[31:0]");
    forever @(posedge clk)
        $display("%-8t | %b    %b    %b   | %h     %b  | %h       | %b     %b",
            $time, ddr_rasb, ddr_casb, ddr_web,
            ddr_ad, ddr_ba, ddr_dq[31:0],
            u_data_valid, read_done);
end

initial begin $dumpfile("tb_read_cycle.vcd"); $dumpvars(0,tb_read_cycle); end

endmodule
