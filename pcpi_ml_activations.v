// Integer-only ML activation coprocessor for PicoRV32 PCPI.
// Implements Q16.16 RELU, L_RELU, SIGM_APPROX, TANH_APPROX.

module pcpi_ml_activations (
	input             clk,
	input             resetn,
	input             pcpi_valid,
	input      [31:0] pcpi_insn,
	input      [31:0] pcpi_rs1,
	input      [31:0] pcpi_rs2,
	output reg        pcpi_wr,
	output reg [31:0] pcpi_rd,
	output reg        pcpi_wait,
	output reg        pcpi_ready
);
	localparam [6:0] OPCODE_CUSTOM0 = 7'b0001011;
	localparam [2:0] F3_ACT = 3'b000;

	localparam [6:0] F7_RELU = 7'd0;
	localparam [6:0] F7_LRELU = 7'd1;
	localparam [6:0] F7_SIGM = 7'd2;
	localparam [6:0] F7_TANH = 7'd3;
	// Internal operation encoding captured in IDLE and used in later FSM states.
	localparam [1:0] OP_RELU = 2'd0;
	localparam [1:0] OP_LRELU = 2'd1;
	localparam [1:0] OP_SIGM = 2'd2;
	localparam [1:0] OP_TANH = 2'd3;

	// 3-cycle PCPI FSM:
	// IDLE    -> capture request and assert wait
	// COMPUTE -> evaluate datapath and register output
	// DONE    -> return ready/wr + result to the CPU
	localparam [1:0] ST_IDLE = 2'd0;
	localparam [1:0] ST_COMPUTE = 2'd1;
	localparam [1:0] ST_DONE = 2'd2;

	// Q16.16 fixed-point constants.
	localparam signed [31:0] Q16_ZERO = 32'sd0;
	localparam signed [31:0] Q16_HALF = 32'sd32768;     // 0.5
	localparam signed [31:0] Q16_THREE_QUARTER = 32'sd49152; // 0.75
	localparam signed [31:0] Q16_SEVEN_EIGHTH = 32'sd57344;  // 0.875
	localparam signed [31:0] Q16_ONE = 32'sd65536;      // 1.0
	localparam signed [31:0] Q16_NEG_ONE = -32'sd65536; // -1.0
	localparam signed [31:0] Q16_ONE_X2 = 32'sd131072;  // 2.0
	// Integer saturation bounds used for overflow-safe intermediate operations.
	localparam signed [31:0] INT32_MIN = 32'sh8000_0000;
	localparam signed [31:0] INT32_MAX = 32'sh7fff_ffff;

	// Decode only our custom activation instruction family:
	// opcode=custom0 and funct3=000, funct7 selects operation.
	wire dec_custom = pcpi_insn[6:0] == OPCODE_CUSTOM0;
	wire dec_f3 = pcpi_insn[14:12] == F3_ACT;
	wire [6:0] dec_f7 = pcpi_insn[31:25];
	wire dec_act = dec_custom && dec_f3;
	wire op_relu = dec_act && (dec_f7 == F7_RELU);
	wire op_lrelu = dec_act && (dec_f7 == F7_LRELU);
	wire op_sigm = dec_act && (dec_f7 == F7_SIGM);
	wire op_tanh = dec_act && (dec_f7 == F7_TANH);
	wire instr_any = op_relu || op_lrelu || op_sigm || op_tanh;
	wire op_fast = op_relu || op_lrelu;

	reg [1:0] state;
	reg [1:0] op_q;
	reg signed [31:0] rs1_q;
	reg signed [31:0] result_q;
	wire signed [31:0] pcpi_rs1_s = pcpi_rs1;
	wire signed [31:0] relu_fast = pcpi_rs1[31] ? Q16_ZERO : pcpi_rs1_s;
	wire signed [31:0] lrelu_fast = pcpi_rs1[31] ? (pcpi_rs1_s >>> 3) : pcpi_rs1_s;

	// Registered operand is used in COMPUTE to break long comb paths from CPU inputs.
	wire signed [31:0] rs1_s = rs1_q;

	wire op_q_tanh = (op_q == OP_TANH);
	wire op_q_sigm = (op_q == OP_SIGM);
	// tanh(x) uses sigmoid(2x); saturate 2x to avoid wraparound on overflow.
	wire x2_pos_ovf = ~rs1_s[31] & rs1_s[30];
	wire x2_neg_ovf = rs1_s[31] & ~rs1_s[30];
	wire signed [31:0] rs1_x2_sat =
		x2_pos_ovf ? INT32_MAX :
		x2_neg_ovf ? INT32_MIN :
		(rs1_s <<< 1);
	wire signed [31:0] nl_x = op_q_tanh ? rs1_x2_sat : rs1_s;
	// Saturating abs() handles INT32_MIN corner case (cannot be negated in 32-bit signed).
	wire signed [31:0] nl_abs =
		nl_x[31] ? ((nl_x == INT32_MIN) ? INT32_MAX : -nl_x) : nl_x;

	// Threshold checks for |x| >= 1,2,4 in Q16.16 using bit-slices (LUT-friendly).
	wire ge_1 = |nl_abs[31:16];
	wire ge_2 = |nl_abs[31:17];
	wire ge_4 = |nl_abs[31:18];

	// Shared multi-segment PWL sigmoid approximation:
	// [0,1): 0.5 + |x|/4
	// [1,2): 0.75 + (|x|-1)/8
	// [2,4): 0.875 + (|x|-2)/16
	// [4,inf): 1.0
	wire signed [31:0] sigm_abs_seg =
		ge_4 ? Q16_ONE :
		ge_2 ? (Q16_SEVEN_EIGHTH + ((nl_abs - Q16_ONE_X2) >>> 4)) :
		ge_1 ? (Q16_THREE_QUARTER + ((nl_abs - Q16_ONE) >>> 3)) :
		       (Q16_HALF + (nl_abs >>> 2));

	// Mirror around 0 for negative input, then derive tanh from sigmoid identity.
	wire signed [31:0] sigm_val = nl_x[31] ? (Q16_ONE - sigm_abs_seg) : sigm_abs_seg;
	wire signed [31:0] tanh_val = (sigm_val <<< 1) - Q16_ONE;

	wire signed [31:0] relu_val = rs1_s[31] ? Q16_ZERO : rs1_s;
	wire signed [31:0] lrelu_val = rs1_s[31] ? (rs1_s >>> 3) : rs1_s;
	// Final operation mux. One shared non-linear datapath is reused by SIGM/TANH.
	wire signed [31:0] result =
		(op_q == OP_RELU) ? relu_val :
		(op_q == OP_LRELU) ? lrelu_val :
		op_q_sigm ? sigm_val :
		op_q_tanh ? tanh_val :
		32'sd0;

	always @(posedge clk) begin
		pcpi_wr <= 1'b0;
		pcpi_ready <= 1'b0;
		pcpi_wait <= 1'b0;
		pcpi_rd <= 32'b0;

		if (!resetn) begin
			// Reset to known IDLE outputs/state.
			state <= ST_IDLE;
			op_q <= OP_RELU;
			rs1_q <= 32'sd0;
			result_q <= 32'sd0;
		end else begin
			case (state)
				ST_IDLE: begin
					if (pcpi_valid && instr_any) begin
						// Accept request and hold CPU with wait while we process.
						pcpi_wait <= 1'b1;
						if (op_fast) begin
							// Fast path: RELU/LRELU result is directly available, skip COMPUTE.
							result_q <= op_relu ? relu_fast : lrelu_fast;
							state <= ST_DONE;
						end else begin
							rs1_q <= pcpi_rs1;
							if (op_sigm)
								op_q <= OP_SIGM;
							else
								op_q <= OP_TANH;
							state <= ST_COMPUTE;
						end
					end
				end

				ST_COMPUTE: begin
					// Register datapath result to isolate timing from response phase.
					pcpi_wait <= 1'b1;
					result_q <= result;
					state <= ST_DONE;
				end

				ST_DONE: begin
					// One-cycle completion pulse back to PicoRV32.
					pcpi_ready <= 1'b1;
					pcpi_wr <= 1'b1;
					pcpi_rd <= result_q;
					state <= ST_IDLE;
				end

				default: begin
					state <= ST_IDLE;
				end
			endcase
		end
	end

	// Silence lint for currently unused rs2 in this instruction family.
	wire _unused_ok = &{1'b0, pcpi_rs2, 1'b0};

endmodule