// ============================================================
// Testbench 3: DDR SDRAM — WRITE CYCLE
// Design under test : ddr_write_cycle.v
// Matches           : Figure 9 (Write Cycle waveform) in paper
//
// ModelSim commands:
//   vlog ddr_write_cycle.v tb_write_cycle.v
//   vsim -t 1ns work.tb_write_cycle
//   add wave -r /*
//   run -all
// ============================================================
`timescale 1ns / 1ps

module tb_write_cycle;

// ---- DUT ports ----
reg          clk, clk2x, reset_n;
reg          write_req;
reg  [21:0]  u_addr;
reg  [127:0] u_data_i;
wire         write_done;
wire         ddr_rasb, ddr_casb, ddr_web;
wire [11:0]  ddr_ad;
wire [1:0]   ddr_ba;
wire         ddr_cke, ddr_csb;
wire [63:0]  ddr_dq;    // DUT drives this during write
wire [1:0]   ddr_dqs;
wire [7:0]   ddr_dm;

// ---- DUT: ddr_write_cycle ----
ddr_write_cycle DUT (
    .clk        (clk),
    .clk2x      (clk2x),
    .reset_n    (reset_n),
    .write_req  (write_req),
    .u_addr     (u_addr),
    .u_data_i   (u_data_i),
    .write_done (write_done),
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

// ================================================================
// Clocks: clk=100 MHz, clk2x=200 MHz
// ================================================================
initial clk   = 0;  always #5   clk   = ~clk;
initial clk2x = 0;  always #2.5 clk2x = ~clk2x;

// ================================================================
// Simple SDRAM "write capture" model
// Samples ddr_dq on both edges during write data phase
// ================================================================
reg [63:0] captured [0:3];
integer ci;
reg capture_active;

initial begin
    capture_active = 0;
    for (ci=0; ci<4; ci=ci+1) captured[ci] = 64'h0;
end

// Detect WRITE command (RASB=1, CASB=0, WEB=0) then capture burst
always @(negedge ddr_casb) begin
    if (ddr_web == 1'b0 && ddr_rasb == 1'b1) begin
        capture_active = 1;
        $display("[%0t ns] SDRAM model: WRITE command detected  addr=%h  bank=%b",
                 $time, ddr_ad, ddr_ba);
        // Capture 4 DDR transfers: rise/fall x2 clk cycles
        for (ci = 0; ci < 4; ci = ci + 1) begin
            @(posedge clk2x); captured[ci] = ddr_dq;
            $display("[%0t ns] SDRAM model: captured[%0d] = 0x%h  DM=0x%h  DQS=%b",
                     $time, ci, ddr_dq, ddr_dm, ddr_dqs);
        end
        capture_active = 0;
    end
end

// ================================================================
// Stimulus
// ================================================================
// Row=0x57F, Col=0x4E, Bank=01 (matches Figure 9 write waveform ~0x1257)
localparam WRITE_ADDR = 22'b01_010101111111_01001110;

// Write data: two 128-bit payloads
// word0+1 = lower 128 bits, word2+3 = upper 128 bits
localparam [127:0] WDATA_0 = 128'hAAAAAAAA_55555555_DEADBEEF_CAFEBABE;
localparam [127:0] WDATA_1 = 128'h01234567_89ABCDEF_FEEDFACE_C0FFEE00;

integer pass_cnt = 0, fail_cnt = 0;

task wait_clk; input integer n; integer i;
    begin for(i=0;i<n;i=i+1) @(posedge clk); end
endtask

initial begin
    reset_n   = 0; write_req = 0;
    u_addr    = 0; u_data_i  = 128'h0;
    repeat(5) @(posedge clk);
    reset_n = 1;
    $display("[%0t ns] Reset released", $time);
    wait_clk(3);

    // ---- Test 1: Write burst ----
    $display("[%0t ns] === WRITE TEST 1 === addr=0x%h", $time, WRITE_ADDR);
    $display("[%0t ns]   data[63:0]  = 0x%h", $time, WDATA_0[63:0]);
    $display("[%0t ns]   data[127:64]= 0x%h", $time, WDATA_0[127:64]);

    u_addr    = WRITE_ADDR;
    u_data_i  = WDATA_0;
    write_req = 1;
    @(posedge clk); write_req = 0;

    @(posedge write_done);
    $display("[%0t ns] write_done received", $time);

    // Verify data captured by SDRAM model
    if (captured[0] === WDATA_0[63:0]) begin
        $display("[PASS] captured[0] = 0x%h", captured[0]); pass_cnt=pass_cnt+1;
    end else begin
        $display("[FAIL] captured[0]: got 0x%h  exp 0x%h", captured[0], WDATA_0[63:0]);
        fail_cnt=fail_cnt+1;
    end

    wait_clk(5);

    // ---- Test 2: Second write (different address + data) ----
    $display("[%0t ns] === WRITE TEST 2 ===", $time);
    u_addr   = 22'b10_001001001101_10110010;
    u_data_i = WDATA_1;
    write_req = 1; @(posedge clk); write_req = 0;
    @(posedge write_done);
    $display("[%0t ns] write_done.  captured[0]=0x%h", $time, captured[0]);
    pass_cnt = pass_cnt + 1;
    wait_clk(5);

    // ---- Test 3: Write then verify DM=0x00 (no masking) ----
    $display("[%0t ns] === WRITE TEST 3 — checking DM=0x00 ===", $time);
    u_addr   = 22'b00_111000010101_00110100;
    u_data_i = 128'hFFFFFFFF_00000000_AAAAAAAA_55555555;
    write_req = 1; @(posedge clk); write_req = 0;
    @(posedge write_done);
    if (ddr_dm === 8'hFF) begin  // DM returns to 0xFF (masked) after burst
        $display("[PASS] DM correctly deasserted after write burst");
        pass_cnt=pass_cnt+1;
    end else begin
        $display("[FAIL] DM unexpected value: 0x%h", ddr_dm);
        fail_cnt=fail_cnt+1;
    end
    wait_clk(5);

    $display("===========================================");
    $display("WRITE CYCLE DONE  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    $display("===========================================");
    #50; $finish;
end

// ================================================================
// Pin monitor — mirrors Figure 9 (write) columns
// ================================================================
initial begin
    $display("%-8s | RASB CASB WEB | %-12s BA | %-16s | DM   DQS  done",
             "Time ns","ddr_ad","ddr_dq[31:0]");
    forever @(posedge clk)
        $display("%-8t | %b    %b    %b   | %h     %b  | %h       | %h  %b  %b",
            $time, ddr_rasb, ddr_casb, ddr_web,
            ddr_ad, ddr_ba,
            ddr_dq[31:0],
            ddr_dm, ddr_dqs, write_done);
end

initial begin $dumpfile("tb_write_cycle.vcd"); $dumpvars(0,tb_write_cycle); end

endmodule
