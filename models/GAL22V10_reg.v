`default_nettype none
module GAL22V10_reg (
	input wire [12:0] in, // Pin {13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1}, 1 is clk
	inout wire [9:0] io   // Pin {14, 15, 16, 17, 18, 19, 20, 21, 22, 23}
);
	// Read in binary JEDEC file
	reg [7:0] jed_bin_file [0:740];
	initial $readmemh("GAL22V10_reg.hex", jed_bin_file);

	// Linearize to a fuse map
	wire [5891:0] fuses;
	genvar i, j;
	generate
		for (i = 0; i < 736; i = i + 1) begin
			for (j = 0; j < 8; j = j + 1) begin
				assign fuses[8*i + j] = jed_bin_file[i + 4][j];
			end
		end
		// Last couple bits
		for (j = 0; j < 4; j = j + 1) begin
			assign fuses[8*736 + j] = jed_bin_file[736 + 4][j];
		end
	endgenerate

	// Extract useful fuses
	wire [9:0] xor_fuses;
	assign xor_fuses = {fuses[5826], fuses[5824], fuses[5822], fuses[5820], fuses[5818],
	                    fuses[5816], fuses[5814], fuses[5812], fuses[5810], fuses[5808]};

	wire [9:0] reg_fuses;
	assign reg_fuses = {fuses[5827], fuses[5825], fuses[5823], fuses[5821], fuses[5819],
	                    fuses[5817], fuses[5815], fuses[5813], fuses[5811], fuses[5809]};

	wire [747:0] sop_fuses [0:9];
	assign sop_fuses[0] = {352'b0, fuses[439:44]};
	assign sop_fuses[1] = {264'b0, fuses[923:440]};
	assign sop_fuses[2] = {176'b0, fuses[1495:924]};
	assign sop_fuses[3] = {88'b0, fuses[2155:1496]};
	assign sop_fuses[4] = fuses[2903:2156];
	assign sop_fuses[5] = fuses[3651:2904];
	assign sop_fuses[6] = {88'b0, fuses[4311:3652]};
	assign sop_fuses[7] = {176'b0, fuses[4883:4312]};
	assign sop_fuses[8] = {264'b0, fuses[5367:4884]};
	assign sop_fuses[9] = {352'b0, fuses[5763:5368]};


	// Interleave in and feedback for SOP inputs
	wire [9:0] feedback;
	wire [21:0] interleaved;
	generate
		for (i = 0; i < 10; i = i + 1) begin
			assign interleaved[2*i +: 2] = {feedback[i], in[i]};
		end
		assign interleaved[21:20] = {in[11], in[10]};
	endgenerate

	// Generate GAL elements
	generate
		for (i = 0; i < 10; i = i + 1) begin
			wire one_sop_out, sop_out;

			// 1SOP
			sop #(
				.NUM_PRODUCTS(1),
				.NUM_INPUTS(22)
			) one_sop_inst (
				.sop_fuses(sop_fuses[i][43:0]),
				.in(interleaved),
				.out(one_sop_out)
			);

			// SOP
			sop #(
				.NUM_PRODUCTS(16),
				.NUM_INPUTS(22)
			) sop_inst (
				.sop_fuses(sop_fuses[i][747:44]),
				.in(interleaved),
				.out(sop_out)
			);

			// OLMC
			olmc olmc_inst (
				.xor_fuse(xor_fuses[i]),
				.reg_fuse(reg_fuses[i]),
				.sop(sop_out),
				.one_sop(one_sop_out),
				.clk(in[0]),
				.io(io[i]),
				.feedback(feedback[i])
			);
		end
	endgenerate

	// Simulation printing
	initial begin
		#1;
		$display("XOR: %b, REG: %b", xor_fuses, reg_fuses);
		$display("Fuses: %x", fuses);

		$display("sop0 %x", sop_fuses[0]);
		$display("sop1 %x", sop_fuses[1]);
		$display("sop2 %x", sop_fuses[2]);
		$display("sop3 %x", sop_fuses[3]);
		$display("sop4 %x", sop_fuses[4]);
		$display("sop5 %x", sop_fuses[5]);
		$display("sop6 %x", sop_fuses[6]);
		$display("sop7 %x", sop_fuses[7]);
		$display("sop8 %x", sop_fuses[8]);
		$display("sop9 %x", sop_fuses[9]);
	end
endmodule

module sop #(
	parameter NUM_PRODUCTS = 7,
	parameter NUM_INPUTS = 16
)(
	input  wire [2*NUM_INPUTS*NUM_PRODUCTS-1:0] sop_fuses,
	input  wire [NUM_INPUTS-1:0] in,
	output reg  out
);
	integer i, j;
	reg match;

	always @ (*) begin
		out = 0;
		for (i = 0; i < NUM_PRODUCTS; i = i + 1) begin
			match = 1;
			for (j = 0; j < NUM_INPUTS; j = j + 1) begin
				if (!sop_fuses[2*NUM_INPUTS*i + 2*j + 0] && !in[j]) match = 0;
				if (!sop_fuses[2*NUM_INPUTS*i + 2*j + 1] &&  in[j]) match = 0;
			end
			if (match) out = 1;
		end
	end
endmodule

module olmc (
	input wire xor_fuse,
	input wire reg_fuse,

	input wire sop,
	input wire one_sop,

	input wire clk,

	inout  wire io,
	output wire feedback
);
	// Internal combined SOP output with optional inversion
	wire out;
	assign out = sop ^ xor_fuse;

	reg reg_out;
	always @ (posedge clk) begin
		reg_out <= out;
	end

	// NOTE: the feedback is inverted if we are registered and ACTIVE HIGH.
	assign feedback = reg_fuse ? !out : !reg_out ^ xor_fuse;

	assign io = reg_fuse ? (one_sop ? !out : 1'bz) : // Combinational
		(one_sop ? !reg_out : 1'bz); // Registered
endmodule
