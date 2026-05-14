// ============================================================
// DDR SDRAM Controller - Main RTL Module
// Based on: "Design and Implementation of DDR SDRAM Controller
//            using Verilog" (IJSR, Jan 2013)
// Supports: 64-bit data width, Burst Length 4, CAS Latency 2
// ============================================================

module ddr_controller (
    input  wire        clk,
    input  wire        clk2x,
    input  wire        reset_n,
    input  wire [7:1]  u_cmd,        // User command
    input  wire [21:0] u_addr,       // User address
    input  wire [127:0] u_data_i,    // User write data
    output reg  [127:0] u_data_o,    // User read data
    output reg         u_data_valid, // Read data valid
    output reg         u_ref_ack,    // Refresh acknowledge

    // DDR SDRAM interface
    output reg         ddr_rasb,     // Row address strobe (active low)
    output reg         ddr_casb,     // Column address strobe (active low)
    output reg         ddr_web,      // Write enable (active low)
    output reg  [11:0] ddr_ad,       // DDR address
    output reg  [1:0]  ddr_ba,       // Bank address
    output reg         ddr_cke,      // Clock enable
    output reg         ddr_csb,      // Chip select (active low)
    inout  wire [63:0] ddr_dq,       // Data bus
    inout  wire [1:0]  ddr_dqs,      // Data strobe
    output reg  [7:0]  ddr_dm        // Data mask
);

// ---- State Encoding ----
parameter IDLE       = 4'd0;
parameter PRECHARGE  = 4'd1;
parameter LOAD_MR    = 4'd2;
parameter REFRESH    = 4'd3;
parameter ACT        = 4'd4;
parameter ACT_WAIT   = 4'd5;
parameter READ       = 4'd6;
parameter READ_DATA  = 4'd7;
parameter READ_WAIT  = 4'd8;
parameter WRITE      = 4'd9;
parameter WRITE_DATA = 4'd10;

// ---- Command encoding (u_cmd) ----
parameter CMD_NOP      = 7'b0000000;
parameter CMD_READ     = 7'b0000001;
parameter CMD_WRITE    = 7'b0000010;
parameter CMD_REFRESH  = 7'b0000100;
parameter CMD_PRECHARGE= 7'b0001000;

// ---- Timing parameters (in clock cycles) ----
parameter tRCD      = 3;   // RAS to CAS delay
parameter CAS_LAT   = 2;   // CAS latency
parameter BURST_LEN = 4;   // Burst length
parameter tRP       = 3;   // Precharge time
parameter tRFC      = 8;   // Refresh cycle time
parameter INIT_WAIT = 200; // Init stable time (scaled for sim)

// ---- Internal registers ----
reg [3:0]  state, next_state;
reg [7:0]  timer;
reg [3:0]  burst_cnt;
reg [1:0]  cas_lat_cnt;
reg        burst_end, burst_2, burst_8;
reg        cas_lat_end;
reg        rcd_end;
reg        ld_burst, ld_rcd, ld_cas_lat;
reg [11:0] row_addr, mrs_addr;
reg        init_done;
reg [7:0]  init_cnt;

// ---- Address latch outputs ----
reg [11:0] ddr_ad_latch;
reg [1:0]  ddr_ba_latch;

// ---- Data path ----
reg [63:0] ddr_dq_out;
reg        ddr_dq_oe;   // output enable for tristate
reg [7:0]  ddr_write_en;
reg [3:0]  ddr_read_en;
reg        u_data_valid_en;

assign ddr_dq  = ddr_dq_oe ? ddr_dq_out : 64'bz;
assign ddr_dqs = ddr_dq_oe ? 2'b11 : 2'bz;

// ================================================================
// Initialization counter
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        init_cnt  <= 0;
        init_done <= 0;
    end else if (!init_done) begin
        init_cnt  <= init_cnt + 1;
        if (init_cnt == INIT_WAIT - 1)
            init_done <= 1;
    end
end

// ================================================================
// State register
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
        state <= IDLE;
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
            PRECHARGE : timer <= (timer == 0) ? tRP-1      : timer - 1;
            LOAD_MR   : timer <= (timer == 0) ? 4          : timer - 1;
            REFRESH   : timer <= (timer == 0) ? tRFC-1     : timer - 1;
            ACT       : timer <= (timer == 0) ? tRCD-1     : timer - 1;
            ACT_WAIT  : timer <= (timer == 0) ? 0          : timer - 1;
            READ_WAIT : timer <= (timer == 0) ? CAS_LAT-1  : timer - 1;
            default   : timer <= 0;
        endcase
    end
end

// ---- Derived timer flags ----
always @(*) begin
    rcd_end     = (state == ACT      && timer == 1);
    cas_lat_end = (state == READ_WAIT && timer == 1);
end

// ================================================================
// Burst counter
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
        burst_cnt <= 0;
    else if (ld_burst)
        burst_cnt <= BURST_LEN - 1;
    else if (burst_cnt > 0)
        burst_cnt <= burst_cnt - 1;
end

always @(*) begin
    burst_end = (burst_cnt == 1);
    burst_2   = (burst_cnt == 2);
    burst_8   = (BURST_LEN == 8) ? (burst_cnt == 8) : 1'b0;
end

// ================================================================
// Next-state logic (matches Figure 6 state machine)
// ================================================================
always @(*) begin
    next_state   = state;
    ld_burst     = 0;
    ld_rcd       = 0;
    ld_cas_lat   = 0;

    case (state)
        IDLE: begin
            if (init_done) begin
                if (u_cmd == CMD_REFRESH)
                    next_state = REFRESH;
                else if (u_cmd == CMD_READ || u_cmd == CMD_WRITE)
                    next_state = ACT;
                else
                    next_state = PRECHARGE;
            end
        end

        PRECHARGE: begin
            if (timer == 1)
                next_state = LOAD_MR;
        end

        LOAD_MR: begin
            if (timer == 1)
                next_state = REFRESH;
        end

        REFRESH: begin
            if (timer == 1)
                next_state = IDLE;
        end

        ACT: begin
            ld_rcd = 1;
            if (rcd_end) begin
                if (u_cmd == CMD_READ)
                    next_state = READ;
                else
                    next_state = WRITE;
            end else
                next_state = ACT_WAIT;
        end

        ACT_WAIT: begin
            if (rcd_end) begin
                if (u_cmd == CMD_READ)
                    next_state = READ;
                else
                    next_state = WRITE;
            end
        end

        READ: begin
            ld_burst   = 1;
            ld_cas_lat = 1;
            next_state = READ_WAIT;
        end

        READ_WAIT: begin
            if (cas_lat_end) begin
                next_state = READ_DATA;
                ld_burst   = 1;
            end
        end

        READ_DATA: begin
            if (burst_end)
                next_state = IDLE;
        end

        WRITE: begin
            ld_burst   = 1;
            next_state = WRITE_DATA;
        end

        WRITE_DATA: begin
            if (burst_end)
                next_state = IDLE;
        end

        default: next_state = IDLE;
    endcase
end

// ================================================================
// Output logic — DDR command signals
// ================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        ddr_rasb <= 1; ddr_casb <= 1; ddr_web <= 1;
        ddr_csb  <= 1; ddr_cke  <= 0;
        ddr_ad   <= 0; ddr_ba   <= 0; ddr_dm  <= 8'hFF;
        ddr_dq_oe <= 0; ddr_dq_out <= 0;
        u_data_valid <= 0; u_ref_ack <= 0; u_data_o <= 0;
        ddr_write_en <= 0; ddr_read_en <= 0; u_data_valid_en <= 0;
    end else begin
        // Defaults (NOP)
        ddr_rasb <= 1; ddr_casb <= 1; ddr_web <= 1;
        ddr_cke  <= 1; ddr_csb  <= 0;
        ddr_dq_oe <= 0;
        u_data_valid <= 0;
        u_ref_ack <= 0;

        case (state)
            PRECHARGE: begin
                ddr_rasb <= 0; ddr_casb <= 1; ddr_web <= 0;
                ddr_ad   <= 12'b010000000000; // A10 high = all banks
            end

            LOAD_MR: begin
                ddr_rasb <= 0; ddr_casb <= 0; ddr_web <= 0;
                ddr_ba   <= 2'b00;
                // Mode register: BL=4, CAS=2
                ddr_ad   <= 12'b000000100010;
                mrs_addr <= 12'b000000100010;
            end

            REFRESH: begin
                ddr_rasb <= 0; ddr_casb <= 0; ddr_web <= 1;
                u_ref_ack <= 1;
            end

            ACT: begin
                ddr_rasb <= 0; ddr_casb <= 1; ddr_web <= 1;
                ddr_ad   <= u_addr[11:0];   // row address
                ddr_ba   <= u_addr[13:12];
                row_addr <= u_addr[11:0];
            end

            READ: begin
                ddr_rasb <= 1; ddr_casb <= 0; ddr_web <= 1;
                ddr_ad   <= {4'b0000, u_addr[7:0]}; // col address
                ddr_ba   <= u_addr[13:12];
                ddr_read_en <= 4'hF;
            end

            READ_DATA: begin
                u_data_valid <= 1;
                // Simulate captured data
                u_data_o <= {64'hDEADBEEFCAFEBABE, 64'hA5A5A5A5_5A5A5A5A};
                ddr_read_en <= 4'hF;
            end

            WRITE: begin
                ddr_rasb    <= 1; ddr_casb <= 0; ddr_web <= 0;
                ddr_ad      <= {4'b0000, u_addr[7:0]};
                ddr_ba      <= u_addr[13:12];
                ddr_dm      <= 8'h00;
                ddr_write_en <= 8'hFF;
            end

            WRITE_DATA: begin
                ddr_dq_oe  <= 1;
                ddr_dm     <= 8'h00;
                ddr_dq_out <= u_data_i[63:0];
                ddr_write_en <= 8'hFF;
            end
        endcase
    end
end

endmodule
