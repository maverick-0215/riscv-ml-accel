`timescale 1ns/1ps

module testbench_pcpi_ml;
	reg clk = 1'b0;
	reg resetn = 1'b0;
	reg pcpi_valid = 1'b0;
	reg [31:0] pcpi_insn = 32'b0;
	reg [31:0] pcpi_rs1 = 32'b0;
	reg [31:0] pcpi_rs2 = 32'b0;
	wire pcpi_wr;
	wire [31:0] pcpi_rd;
	wire pcpi_wait;
	wire pcpi_ready;

	integer passed = 0;
	integer failed = 0;

	localparam [6:0] OPCODE_CUSTOM0 = 7'b0001011;
	localparam [2:0] F3_ACT = 3'b000;
	localparam [6:0] F7_RELU = 7'd0;
	localparam [6:0] F7_LRELU = 7'd1;
	localparam [6:0] F7_SIGM = 7'd2;
	localparam [6:0] F7_TANH = 7'd3;

	always #5 clk = ~clk;

	pcpi_ml_activations dut (
		.clk(clk),
		.resetn(resetn),
		.pcpi_valid(pcpi_valid),
		.pcpi_insn(pcpi_insn),
		.pcpi_rs1(pcpi_rs1),
		.pcpi_rs2(pcpi_rs2),
		.pcpi_wr(pcpi_wr),
		.pcpi_rd(pcpi_rd),
		.pcpi_wait(pcpi_wait),
		.pcpi_ready(pcpi_ready)
	);

	function [31:0] mk_insn;
		input [6:0] funct7;
		begin
			mk_insn = {funct7, 5'd0, 5'd0, F3_ACT, 5'd0, OPCODE_CUSTOM0};
		end
	endfunction

	task run_case;
		input [8*32-1:0] name;
		input [6:0] funct7;
		input [31:0] rs1;
		input [31:0] expected;
		integer timeout;
		begin
			@(posedge clk);
			pcpi_insn <= mk_insn(funct7);
			pcpi_rs1 <= rs1;
			pcpi_rs2 <= 32'b0;
			pcpi_valid <= 1'b1;

			timeout = 0;
			while (!pcpi_ready && timeout < 30) begin
				timeout = timeout + 1;
				@(posedge clk);
			end

			if (!pcpi_ready || !pcpi_wr) begin
				failed = failed + 1;
				$display("FAIL %-20s : no ready/wr response (timeout)", name);
			end else if (pcpi_rd !== expected) begin
				failed = failed + 1;
				$display("FAIL %-20s : got=0x%08x expected=0x%08x", name, pcpi_rd, expected);
			end else begin
				passed = passed + 1;
				$display("PASS %-20s : result=0x%08x", name, pcpi_rd);
			end

			@(posedge clk);
			pcpi_valid <= 1'b0;
			pcpi_insn <= 32'b0;
			pcpi_rs1 <= 32'b0;
		end
	endtask

	initial begin
		repeat (4) @(posedge clk);
		resetn = 1'b1;
		repeat (2) @(posedge clk);

		// Q16.16 constants used by this testbench.
		run_case("relu_pos",  F7_RELU,  32'h0001_8000, 32'h0001_8000); // +1.5 -> +1.5
		run_case("relu_neg",  F7_RELU,  32'hFFFF_0000, 32'h0000_0000); // -1.0 -> 0
		run_case("lrelu_neg", F7_LRELU, 32'hFFFF_0000, 32'hFFFF_E000); // -1.0 -> -0.125
		run_case("sigm_zero", F7_SIGM,  32'h0000_0000, 32'h0000_8000); // sigmoid(0)=0.5
		run_case("sigm_hi",   F7_SIGM,  32'h0004_0000, 32'h0001_0000); // saturates near 1.0
		run_case("tanh_zero", F7_TANH,  32'h0000_0000, 32'h0000_0000); // tanh(0)=0
		run_case("tanh_hi",   F7_TANH,  32'h0004_0000, 32'h0001_0000); // saturates near +1.0

		$display("Summary: passed=%0d failed=%0d", passed, failed);
		if (failed != 0)
			$fatal(1, "PCPI ML activation test failed");
		$finish;
	end

endmodule
