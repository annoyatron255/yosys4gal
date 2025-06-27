#!/usr/bin/env -S yosys -c
yosys -import
set scriptDir [file dirname [file normalize [info script]]]
# Parse arguments
if {$argc < 3} {
	puts "USAGE: $argv0 -- <JEDEC_FILE> <PCF_FILE> <VERILOG FILES> ..."
	exit
}

set jedec_file [lindex $argv 0]
set pcf_file [lindex $argv 1]
set verilog_files [lrange $argv 2 end]

# Convert JEDEC file to bin
exec jedutil -convert $jedec_file __temp.bin

# Find chip being used
set jedec_bin_size [file size __temp.bin]
if {$jedec_bin_size == 279} {
	set chip GAL16V8
	set pin_mapping [dict create 1 "clk" 2 "in\[0\]" 3 "in\[1\]" 4 "in\[2\]" 5 "in\[3\]" 6 "in\[4\]" 7 "in\[5\]" 8 "in\[6\]" 9 "in\[7\]" 11 "oe_n" 12 "io\[7\]" 13 "io\[6\]" 14 "io\[5\]" 15 "io\[4\]" 16 "io\[3\]" 17 "io\[2\]" 18 "io\[1\]" 19 "io\[0\]"]
} elseif {$jedec_bin_size == 741} {
	set chip GAL22V10
	set pin_mapping [dict create 1 "in\[0\]" 2 "in\[1\]" 3 "in\[2\]" 4 "in\[3\]" 5 "in\[4\]" 6 "in\[5\]" 7 "in\[6\]" 8 "in\[7\]" 9 "in\[8\]" 10 "in\[9\]" 11 "in\[10\]" 12 "in\[11\]" 13 "in\[12\]" 14 "io\[9\]" 15 "io\[8\]" 16 "io\[7\]" 17 "io\[6\]" 18 "io\[5\]" 19 "io\[4\]" 20 "io\[3\]" 21 "io\[2\]" 22 "io\[1\]" 23 "io\[0\]"]
} else {
	puts "Error: Unknown chip for JEDEC file"
	exit
}
puts "Chip found to be $chip"

# Convert binary JEDEC file to hex for Verilog
exec xxd -ps -c 1 __temp.bin ${chip}_reg.hex
exec rm __temp.bin

# Read and synthesize original Verilog
read_verilog $verilog_files
hierarchy -auto-top

tribuf
synth
#yosys proc
#yosys memory
#clean -purge
flatten

splitnets -ports
yosys rename -top __original
select -module __original

# Process PCF file and rename ports
set used [list]
set pcf_fp [open $pcf_file r]
foreach line [split [read $pcf_fp] "\n"] {
	puts $line
	if {[regexp {set_io\s+(.*)\s+([0-9]+)} $line -> net pin]} {
		# Rename nets to match GAL model
		yosys rename $net __[dict get $pin_mapping $pin]

		# Mark as used
		lappend used [dict get $pin_mapping $pin]
	}
}

select -clear
design -stash __original

# Read and synthesize GAL model
read_verilog ${scriptDir}/${chip}_wrapper.v ${scriptDir}/${chip}_reg.v

tribuf
synth
#yosys proc
#yosys memory
#clean -purge
flatten

splitnets -ports
select -module __wrapper

# Delete extra "unused" ports
foreach pin_name [dict values $pin_mapping] {
	if {[lsearch -exact $used $pin_name] >= 0} {
		puts "$pin_name is used"
	} elseif {$pin_name == "oe_n" && $chip == "GAL16V8"} {
		puts "$pin_name is not used"
		# Enable registered outputs if net unused
		connect -set __oe_n '0
		delete -port __$pin_name
	} else {
		puts "$pin_name is not used"
		delete -port __$pin_name
	}
}
select -clear

# Make and check equivalence circuit
design -copy-from __original -as __original A:top

equiv_make __original __wrapper equiv
tribuf -formal equiv
equiv_induct equiv
equiv_status -assert equiv
