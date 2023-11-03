`default_nettype none

/*

I/O Layout

Inputs:

IN0 - CLK (10MHz)
IN1 - RST
IN2 - HR++ (setting)
IN3 - MIN++ (setting)
IN4 - HH:MM / 00:SS select

Outputs:

2 74HC595 shift registers chained together and a 4x7seg display connected as per https://wokwi.com/projects/362790299842764801

OUT0 - CLK
OUT1 - DATA
OUT2 - LATCH_EN
OUT3 - 0.5 Hz signal from divider for debug

*/

module tt_um_7segx4_clock_abhishek_top #( parameter MAX_COUNT = 10_000_000 ) (
  input  wire [7:0] ui_in,    // Dedicated inputs - connected to the input switches
  output wire [7:0] uo_out,   // Dedicated outputs - connected to the 7 segment display
  input  wire [7:0] uio_in,   // IOs: Bidirectional Input path
  output wire [7:0] uio_out,  // IOs: Bidirectional Output path
  output wire [7:0] uio_oe,   // IOs: Bidirectional Enable path (active high: 0=input, 1=output)
  input  wire       ena,      // will go high when the design is enabled
  input  wire       clk,      // clock
  input  wire       rst_n     // reset_n - low to reset

);
    wire reset = !rst_n;

    wire sw_inc_hr = ui_in[0];
    wire sw_inc_min = ui_in[1];
    wire sw_disp_sw = ui_in[2];

    wire inc_hr;
    wire inc_min;
    wire disp_sw;

    debouncer deboucerForHrSw(.i_rst(reset), .i_clk(clk), .i_btn(sw_inc_hr), .o_debounced(inc_hr));
    debouncer deboucerForMinSw(.i_rst(reset), .i_clk(clk), .i_btn(sw_inc_min), .o_debounced(inc_min));
    debouncer deboucerForDispSw(.i_rst(reset), .i_clk(clk), .i_btn(sw_disp_sw), .o_debounced(disp_sw));

    wire sclk_out;
    wire data_out;
    wire latch_en_out;
    wire clkHalfHz_out;

    assign uo_out[0] = sclk_out;
    assign uo_out[1] = data_out;
    assign uo_out[2] = latch_en_out;
    assign uo_out[3] = clkHalfHz_out;
    assign uo_out[7:4] = 4'b0;

    assign uio_out = 8'b11111111;
    assign uio_oe = 8'b11111111;

    // external clock is 8.192kHz, so need 14 bit counter
    reg [24:0] second_counter;

    // Display state
    //   0 -> displaying hour and minute, blinking colon
    //   1 -> steady colon, seconds only
    reg disp_state;

    // Button actions
    //   increment hour (rollover 00-23), reset seconds to zero
    //   increment mins (rollover 00-59), reset seconds to zero
    //   switch screen from state 0 to state 1 and return in 3 seconds
    localparam REVERT_SECONDS = 3;
    localparam REVERT_SECOND_BITS = $clog2(REVERT_SECONDS);
    reg [3:0] revert_timer;

    wire second_pulse = second_counter == MAX_COUNT;
    wire sec_to_min;
    wire min_to_hr;
    wire [6:0] seconds;

    // slow clock out on the last gpio
    assign clkHalfHz_out = seconds[0];

    reg colon;
    reg [3:0] disp_data[0:3];

    reg [1:0] digit_index; // current digit being refreshed

    always @(posedge clk) begin
        // if reset, set counter to 0
        if (!rst_n) begin
            second_counter <= 0;
            disp_state <= 0;
            digit_index <= 0;
            revert_timer <= 0;
            colon <= 0;
            disp_data[0] <= 0;
            disp_data[1] <= 0;
            disp_data[2] <= 0;
            disp_data[3] <= 0;
        end else begin
            if (second_counter == MAX_COUNT) begin
                // reset counter
                second_counter <= 0;
                // Display data
                if (disp_state == 0) begin
                    colon <= seconds[0];
                    disp_data[0] <= hr_tens;
                    disp_data[1] <= hr_ones;
                    disp_data[2] <= min_tens;
                    disp_data[3] <= min_ones;
                end else begin
                    colon <= 1;
                    disp_data[0] <= 4'd10;
                    disp_data[1] <= 4'd10;
                    disp_data[2] <= sec_tens;
                    disp_data[3] <= sec_ones;
                end
                if (revert_timer != 0) begin
                    revert_timer <= revert_timer - 1;
                    if (revert_timer == 0) begin
                        disp_state <= 0;
                    end
                end
            end else begin
                second_counter <= second_counter + 1'b1;
                digit_index <= digit_index + 1'b1;
                if (disp_sw) begin
                    disp_state <= 1;
                    revert_timer <= REVERT_SECONDS;
                end
            end
        end
    end

    wire [3:0] hr_tens;
    wire [3:0] hr_ones;
    wire [3:0] min_tens;
    wire [3:0] min_ones;
    wire [3:0] sec_tens;
    wire [3:0] sec_ones;

    // instantiate segment display
    bcd_counter #(.MAX_COUNT(23)) hr_counter ( .clk_i(clk), .rst_i(reset), .increment_i(min_to_hr | inc_hr), .count_tens_o(hr_tens), .count_ones_o(hr_ones));
    bcd_counter #(.MAX_COUNT(59)) min_counter ( .clk_i(clk), .rst_i(reset), .increment_i(sec_to_min | inc_min), .count_tens_o(min_tens), .count_ones_o(min_ones), .overflow_o(min_to_hr));
    bcd_counter #(.MAX_COUNT(59)) sec_counter ( .clk_i(clk), .rst_i(reset), .increment_i(second_pulse), .count_tens_o(sec_tens), .count_ones_o(sec_ones), .overflow_o(sec_to_min), .count_o(seconds));

    wire [15:0] shift_data;

    seg7x4withColon seg7x4withColon(
        .disp_i(disp_data[digit_index]),
        .colon_i(colon),
        .digit_i(digit_index),
        .data_o(shift_data)
    );

    shift_register_595 #( .NUM_ICS(2) ) shiftReg(
        .clk_i(clk),
        .rst_i(reset),

        .trigger_i(1'b1),
        .data_i(shift_data),

        .sclk_o(sclk_out),
        .data_o(data_out),
        .latch_en_o(latch_en_out)
    );

endmodule
