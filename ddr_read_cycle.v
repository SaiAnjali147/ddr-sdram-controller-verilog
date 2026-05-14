// ============================================================
// DDR SDRAM Controller — READ CYCLE Module (RTL Design)
// Paper: "Design and Implementation of DDR SDRAM Controller
//         using Verilog" (IJSR, Jan 2013)
// Spec:  64-bit data, Burst Length = 4, CAS Latency = 2
//
// This module handles:
//   1. ACT  command  — opens the target row
//   2. READ command  — issues column address
//   3. CAS latency   — 2-cycle pipeline wait
//   4. Data capture  — samples ddr_dq on both clock edges (DDR)
//   5. Output sync   — resynchronises to single-rate user clock
// ============================================================

`timescale 1ns / 1ps

module ddr_read_cycle (
    // ---- System ----
    input  wire         clk,          // 100 MHz system clock
    input  wire         clk2x,        // 200 MHz DDR clock
    input  wire         reset_n,      // Active-low async reset

    // ---- User interface ----
    input  wire         read_req,     // Pulse high to start a read
    input  wire [21:0]  u_addr,       // {bank[1:0], row[11:0], col[7:0]}
    output reg  [127:0] u_data_o,     // Captured read data (2x64-bit words)
    output reg          u_data_valid, // High when u_data_o is valid
    output reg          read_done,    // Pulses high after full burst

    // ---- DDR SDRAM bus ----
    output reg          ddr_rasb,     // Row address strobe (active low)
    output reg          ddr_casb,     // Column address strobe (active low)
    output reg          ddr_web,      // Write enable — kept HIGH for reads
    output reg  [11:0]  ddr_ad,       // Address bus (row then column)
    output reg  [1:0]   ddr_ba,       // Bank address
    output reg          ddr_cke,      // Clock enable
    output reg          ddr_csb,      // Chip select (active low)
    input  wire [63:0]  ddr_dq,       // Data bus (input during read)
    input  wire [1:0]   ddr_dqs       // Data strobe (input during read)
);

// ================================================================
// Parameters
// ================================================================
parameter CAS_LAT   = 2;   // CAS latency in clk cycles
parameter BURST_LEN = 4;   // Number of data transfers
parameter tRCD      = 3;   // RAS-to-CAS delay (cycles)
parameter tRP       = 3;   // Precharge time (cycles)

// ================================================================
// State machine encoding
// ================================================================
parameter S_IDLE       = 3'd0;
parameter S_ACT        = 3'd1;  // Activate row
parameter S_ACT_WAIT   = 3'd2;  // Wait tRCD
parameter S_READ_CMD   = 3'd3;  // Issue READ command
parameter S_CAS_WAIT   = 3'd4;  // CAS latency pipeline
parameter S_READ_DATA  = 3'd5;  // Capture burst data
parameter S_DONE       = 3'd6;  // Signal completion

reg [2:0] state, next_state;

// ================================================================
// Internal counters
// ================================================================
reg [3:0] timer;          // General timing counter
reg [2:0] burst_cnt;      // Counts captured words (0..BURST_LEN-1)
reg [1:0] cas_cnt;        // Counts CAS latency cycles

// ================================================================
// DDR data capture registers
// Edge capture on both rising and falling edges of clk2x
// ================================================================
reg [63:0] dq_rise;       // Data sampled on rising  edge of clk2x
reg [63:0] dq_fall;       // Data sampled on falling edge of clk2x
reg        capture_en;    // Enable DDR data capture
reg        capture_phase; // 0 = waiting for rise, 1 = got rise

// ---- Capture on RISING edge of clk2x ----
always @(posedge clk2x or negedge reset_n) begin
    if (!reset_n)
        dq_rise <= 64'h0;
    else if (capture_en)
        dq_rise <= ddr_dq;
end

// ---- Capture on FALLING edge of clk2x ----
always @(negedge clk2x or negedge reset_n) begin
    if (!reset_n)
        dq_fall <= 64'h0;
    else if (capture_en)
        dq_fall <= ddr_dq;
end

// ================================================================
// State register
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
        state <= S_IDLE;
    else
        state <= next_state;
end

// ================================================================
// Timer
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
        timer <= 0;
    else begin
        case (state)
            S_ACT_WAIT  : timer <= (timer == 0) ? 0 : timer - 1;
            S_CAS_WAIT  : timer <= (timer == 0) ? 0 : timer - 1;
            S_ACT       : timer <= tRCD - 1;
            S_READ_CMD  : timer <= CAS_LAT - 1;
            default     : timer <= 0;
        endcase
    end
end

// ================================================================
// CAS latency counter
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
        cas_cnt <= 0;
    else if (state == S_READ_CMD)
        cas_cnt <= CAS_LAT - 1;
    else if (state == S_CAS_WAIT && cas_cnt > 0)
        cas_cnt <= cas_cnt - 1;
end

// ================================================================
// Burst counter
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
        burst_cnt <= 0;
    else if (state == S_READ_DATA)
        burst_cnt <= (burst_cnt == BURST_LEN - 1) ? 0 : burst_cnt + 1;
    else
        burst_cnt <= 0;
end

// ================================================================
// Next-state logic
// ================================================================
always @(*) begin
    next_state = state;
    case (state)
        S_IDLE:
            if (read_req)
                next_state = S_ACT;

        S_ACT:
            next_state = S_ACT_WAIT;

        S_ACT_WAIT:
            if (timer == 1)
                next_state = S_READ_CMD;

        S_READ_CMD:
            next_state = S_CAS_WAIT;

        S_CAS_WAIT:
            if (cas_cnt == 1)
                next_state = S_READ_DATA;

        S_READ_DATA:
            if (burst_cnt == BURST_LEN - 1)
                next_state = S_DONE;

        S_DONE:
            next_state = S_IDLE;

        default: next_state = S_IDLE;
    endcase
end

// ================================================================
// Output / command logic
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        ddr_rasb     <= 1; ddr_casb  <= 1; ddr_web  <= 1;
        ddr_cke      <= 0; ddr_csb   <= 1;
        ddr_ad       <= 12'h0; ddr_ba <= 2'b00;
        u_data_o     <= 128'h0;
        u_data_valid <= 0;
        read_done    <= 0;
        capture_en   <= 0;
        capture_phase<= 0;
    end else begin
        // Defaults — NOP
        ddr_rasb     <= 1; ddr_casb <= 1; ddr_web <= 1;
        ddr_cke      <= 1; ddr_csb  <= 0;
        u_data_valid <= 0;
        read_done    <= 0;
        capture_en   <= 0;

        case (state)
            // --------------------------------------------------
            // S_ACT: Assert RAS, put row address on bus
            // --------------------------------------------------
            S_ACT: begin
                ddr_rasb <= 0;   // RAS active
                ddr_casb <= 1;
                ddr_web  <= 1;
                ddr_ad   <= u_addr[11:0];   // row address
                ddr_ba   <= u_addr[13:12];  // bank
            end

            // --------------------------------------------------
            // S_ACT_WAIT: NOP while waiting tRCD
            // --------------------------------------------------
            S_ACT_WAIT: begin
                ddr_rasb <= 1; ddr_casb <= 1; ddr_web <= 1;
            end

            // --------------------------------------------------
            // S_READ_CMD: Assert CAS, put column address on bus
            // --------------------------------------------------
            S_READ_CMD: begin
                ddr_rasb <= 1;
                ddr_casb <= 0;   // CAS active
                ddr_web  <= 1;   // WE high = READ
                ddr_ad   <= {4'b0000, u_addr[7:0]};  // column address
                ddr_ba   <= u_addr[13:12];
            end

            // --------------------------------------------------
            // S_CAS_WAIT: NOP during CAS latency (2 cycles)
            // --------------------------------------------------
            S_CAS_WAIT: begin
                ddr_rasb <= 1; ddr_casb <= 1; ddr_web <= 1;
                // Enable capture in last CAS wait cycle so data
                // is ready on the FIRST read-data clock edge
                if (cas_cnt == 1)
                    capture_en <= 1;
            end

            // --------------------------------------------------
            // S_READ_DATA: Capture DDR data from ddr_dq
            //   burst_cnt 0,1 => u_data_o[63:0]
            //   burst_cnt 2,3 => u_data_o[127:64]
            // --------------------------------------------------
            S_READ_DATA: begin
                capture_en   <= 1;
                u_data_valid <= 1;
                // Pack two DDR-sampled 64-bit words into 128-bit output
                case (burst_cnt)
                    3'd0: u_data_o[63:0]   <= dq_rise; // rising  edge word 0
                    3'd1: u_data_o[63:0]   <= dq_fall; // falling edge word 1
                    3'd2: u_data_o[127:64] <= dq_rise; // rising  edge word 2
                    3'd3: u_data_o[127:64] <= dq_fall; // falling edge word 3
                endcase
            end

            // --------------------------------------------------
            // S_DONE: assert read_done for one cycle
            // --------------------------------------------------
            S_DONE: begin
                read_done    <= 1;
                u_data_valid <= 0;
                capture_en   <= 0;
            end
        endcase
    end
end

endmodule
