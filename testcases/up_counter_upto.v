module test (
	input clk,

	output reg [0:7] counter
);

always @ (posedge clk) begin
	counter <= counter + 1;
end

endmodule
