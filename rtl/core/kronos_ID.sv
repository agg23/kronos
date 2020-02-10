// Copyright (c) 2020 Sonal Pinto
// SPDX-License-Identifier: Apache-2.0


/*
Kronos RISC-V 32I Decoder
The 32b instruction and PC from the IF stage is decoded
into a generic form:

    RESULT1 = ALU( OP1, OP2 )
    RESULT2 = ADD( OP3, OP4 )
    HAZARD_CHECKS
    WB_CONTROLS

where,
    OP1-4       : Operands, where OP1/2 are primary kronos_ALU operands,
                  and OP3/4 are secondary adder operands
                  Each operand can take one of many values as listed below,
                  OP1 <= PC, ZERO, REG[rs1]
                  OP2 <= IMM, FOUR, REG[rs2]
                  OP3 <= REG[rs2], PC
                  OP4 <= REG[rs1], IMM, ZERO
    EX_CTRL     : Execute stage controls
    WB_CTRL     : Write back stage controls which perform an action using
                  RESULT1/2
    RESULT1     : register write data
                  memory write addr
                  branch condition
    RESULT2     : memory address
                  branch target

EX_CTRL,
    cin, rev, uns , eq, inv, align, sel  
    Check kronos_alu for details

HAZARD CHECKS,
    rs1, rs2, op#_regrd
    Check kronos_EX for details

WB_CTRL,
    rd          : register write select
    rd_write    : register write enable
    branch      : unconditional branch
    branch_cond : conditional branch
    ld_size     : memory load size - byte, half-word or word
    ld_sign     : sign extend loaded data
    st          : store
    illegal     : illegal instruction
    Check kronos_WB for details


Note: The 4 operand requirement comes from the RISC-V's Branch instructions which perform
    if compare(rs1, rs2):
        pc <= pc + Imm

    Which consumes rs1, rs2, pc and Imm at the same time!
*/


module kronos_ID
    import kronos_types::*;
(
    input  logic        clk,
    input  logic        rstz,
    // IF/ID interface
    input  pipeIFID_t   fetch,
    input  logic        pipe_in_vld,
    output logic        pipe_in_rdy,
    // ID/EX interface
    output pipeIDEX_t   decode,
    output logic        pipe_out_vld,
    input  logic        pipe_out_rdy,
    // REG Write
    input  logic [31:0] regwr_data,
    input  logic [4:0]  regwr_sel,
    input  logic        regwr_en
);

parameter logic [31:0] ZERO   = 32'h0;
parameter logic [31:0] FOUR   = 32'h4;

logic [31:0] IR, PC;
logic [4:0] OP;
logic [6:0] opcode;
logic [4:0] rs1, rs2, rd;
logic [2:0] funct3;
logic [6:0] funct7;

logic instr_valid;
logic illegal_opcode;

logic regrd_rs1_en, regrd_rs2_en;
logic [31:0] regrd_rs1_data, regrd_rs2_data;
logic [31:0] regrd_rs1, regrd_rs2;
logic regwr_rd_en;

logic sign;
logic format_I;
logic format_J;
logic format_S;
logic format_B;
logic format_U;

// Immediate Operand segments
// A: [0]
// B: [4:1]
// C: [10:5]
// D: [11]
// E: [19:12]
// F: [31:20]
logic           ImmA;
logic [3:0]     ImmB;
logic [5:0]     ImmC;
logic           ImmD;
logic [7:0]     ImmE;
logic [11:0]    ImmF;

logic [31:0] immediate;

// Execute Stage controls
logic       cin;
logic       rev;
logic       uns;
logic       eq;
logic       inv;
logic       align;
logic [2:0] sel;


// ============================================================
// [rv32i] Instruction Decoder

assign IR = fetch.ir;
assign PC = fetch.pc;

// Aliases to IR segments
assign opcode = IR[6:0];
assign OP = opcode[6:2];

assign rs1 = IR[19:15];
assign rs2 = IR[24:20];
assign rd  = IR[11: 7];

assign funct3 = IR[14:12];
assign funct7 = IR[31:25];

// opcode is illegal if LSB 2b are not 2'b11
assign illegal_opcode = opcode[1:0] != 2'b11;


// ============================================================
// Integer Registers

/*
Note: Since this ID module is geared towards FPGA, 
    Dual-Port Embedded Block Ram will be used to implement the 32x32 registers.
    Register (EBR) access is clocked. We need to read two registers on 
    the off-edge to have it ready by the next active edge.

    In the iCE40UP5K this would inefficiently take 4 EBR (each being 16x256)
*/

logic [31:0] REG1 [32] /* synthesis syn_ramstyle = "no_rw_check" */;
logic [31:0] REG2 [32] /* synthesis syn_ramstyle = "no_rw_check" */;

assign regrd_rs1_en = OP == INSTR_OPIMM ||  OP == INSTR_OP;
assign regrd_rs2_en = OP == INSTR_OP;

assign regwr_rd_en = (rd != 0); // opcode != br|st|misc|system

// REG read
always_ff @(negedge clk) begin
    if (regrd_rs1_en) regrd_rs1_data <= REG1[rs1];
    if (regrd_rs2_en) regrd_rs2_data <= REG2[rs2];
end

always_comb begin
    // Forward the latest write-data if requried
    // Also blank out if x0 is being read
    if (regrd_rs1_en && rs1 != '0)
        regrd_rs1 = (regwr_en && regwr_sel == rs1) ? regwr_data : regrd_rs1_data;
    else regrd_rs1 = '0;

    if (regrd_rs2_en && rs2 != '0)
        regrd_rs2 = (regwr_en && regwr_sel == rs2) ? regwr_data : regrd_rs2_data;
    else regrd_rs2 = '0;
end

// REG Write
always_ff @(posedge clk) begin
    if (regwr_en) begin
        REG1[regwr_sel] <= regwr_data;
        REG2[regwr_sel] <= regwr_data;
    end
end


// ============================================================
// Immediate Decoder

assign sign = IR[31];

always_comb begin
    // Instruction format --- used to decode Immediate 
    format_I = OP == INSTR_OPIMM;
    format_J = 1'b0;
    format_S = 1'b0;
    format_B = 1'b0;
    format_U = OP == INSTR_LUI || OP == INSTR_AUIPC;

    // Immediate Segment A - [0]
    if (format_I) ImmA = IR[20];
    else if (format_S) ImmA = IR[7];
    else ImmA = 1'b0; // B/J/U
    
    // Immediate Segment B - [4:1]
    if (format_U) ImmB = 4'b0;
    else if (format_I || format_J) ImmB = IR[24:21];
    else ImmB = IR[11:8]; // S/B

    // Immediate Segment C - [10:5]
    if (format_U) ImmC = 6'b0;
    else ImmC = IR[30:25];

    // Immediate Segment D - [11]
    if (format_U) ImmD = 1'b0;
    else if (format_B) ImmD = IR[7];
    else if (format_J) ImmD = IR[20];
    else ImmD = sign;

    // Immediate Segment E - [19:12]
    if (format_U || format_J) ImmE = IR[19:12];
    else ImmE = {8{sign}};
    
    // Immediate Segment F - [31:20]
    if (format_U) ImmF = IR[31:20];
    else ImmF = {12{sign}};
end

// As A-Team's Hannibal would say, "I love it when a plan comes together"
assign immediate = {ImmF, ImmE, ImmD, ImmC, ImmB, ImmA};


// ============================================================
// Execute Stage Operation Decoder

always_comb begin
    // Default ALU Operation: ADD 
    //  result1 <= ALU.adder
    //  result2 <= unaligned add
    cin     = 1'b0;
    rev     = 1'b0;
    uns     = 1'b0;
    eq      = 1'b0;
    inv     = 1'b0;
    align   = 1'b0;
    sel     = ALU_ADDER;
    instr_valid = 1'b0;

    // ALU Controls are decoded using {funct7, funct3, OP}
    /* verilator lint_off CASEINCOMPLETE */
    case(OP)
    // --------------------------------
    INSTR_LUI,
    INSTR_AUIPC: instr_valid = 1'b1;
    // --------------------------------
    INSTR_OPIMM: begin
        case(funct3)
            3'b000: begin // ADDI
                instr_valid = 1'b1;
            end
            3'b010: begin // SLTI
                cin = 1'b1;
                sel = ALU_COMP;
                instr_valid = 1'b1;
            end

            3'b011: begin // SLTIU
                cin = 1'b1;
                uns = 1'b1;
                sel = ALU_COMP;
                instr_valid = 1'b1;
            end

            3'b100: begin // XORI
                sel = ALU_XOR;
                instr_valid = 1'b1;
            end

            3'b110: begin // ORI
                sel = ALU_OR;
                instr_valid = 1'b1;
            end

            3'b111: begin // ANDI
                sel = ALU_AND;
                instr_valid = 1'b1;
            end

            3'b001: begin // SLLI
                if (funct7 == 7'd0) begin
                    rev = 1'b1;
                    uns = 1'b1;
                    sel = ALU_SHIFT;
                    instr_valid = 1'b1;
                end
            end

            3'b101: begin // SRLI/SRAI
                if (funct7 == 7'd0) begin
                    uns = 1'b1;
                    sel = ALU_SHIFT;
                    instr_valid = 1'b1;
                end
                else if (funct7 == 7'd32) begin
                    sel = ALU_SHIFT;
                    instr_valid = 1'b1;
                end
            end
        endcase // funct3
    end
    // --------------------------------
    INSTR_OP: begin
        case(funct3)
            3'b000: begin // ADD/SUB
                if (funct7 == 7'd0) begin
                    instr_valid = 1'b1;
                end
                else if (funct7 == 7'd32) begin
                    cin = 1'b1;
                    instr_valid = 1'b1;
                end
            end

            3'b001: begin // SLL
                if (funct7 == 7'd0) begin
                    rev = 1'b1;
                    uns = 1'b1;
                    sel = ALU_SHIFT;
                    instr_valid = 1'b1;
                end
            end

            3'b010: begin // SLT
                if (funct7 == 7'd0) begin
                    cin = 1'b1;
                    sel = ALU_COMP;
                    instr_valid = 1'b1;
                end
            end

            3'b011: begin // SLTU
                if (funct7 == 7'd0) begin
                    cin = 1'b1;
                    uns = 1'b1;
                    sel = ALU_COMP;
                    instr_valid = 1'b1;
                end
            end

            3'b100: begin // XOR
                if (funct7 == 7'd0) begin
                    sel = ALU_XOR;
                    instr_valid = 1'b1;
                end
            end

            3'b101: begin // SRL/SRA
                if (funct7 == 7'd0) begin
                    uns = 1'b1;
                    sel = ALU_SHIFT;
                    instr_valid = 1'b1;
                end
                else if (funct7 == 7'd32) begin
                    sel = ALU_SHIFT;
                    instr_valid = 1'b1;
                end
            end

            3'b110: begin // OR
                if (funct7 == 7'd0) begin
                    sel = ALU_OR;
                    instr_valid = 1'b1;
                end
            end

            3'b111: begin // AND
                if (funct7 == 7'd0) begin
                    sel = ALU_AND;
                    instr_valid = 1'b1;
                end
            end
        endcase // funct3
    end
    endcase // OP
    /* verilator lint_on CASEINCOMPLETE */
end


// ============================================================
// Instruction Decode Output Pipe (decoded instruction)

always_ff @(posedge clk or negedge rstz) begin
    if (~rstz) begin
        pipe_out_vld <= 1'b0;
    end
    else begin
        if(pipe_in_vld && pipe_in_rdy) begin
            pipe_out_vld <= 1'b1;

            // Hazard check
            decode.rs1          <= (regrd_rs1_en) ? rs1 : '0;
            decode.rs2          <= (regrd_rs2_en) ? rs2 : '0;
            decode.op1_regrd    <= 1'b0;
            decode.op2_regrd    <= 1'b0;
            decode.op3_regrd    <= 1'b0;
            decode.op4_regrd    <= 1'b0;

            // EX controls
            decode.cin   <= cin;
            decode.rev   <= rev;
            decode.uns   <= uns;
            decode.eq    <= eq;
            decode.inv   <= inv;
            decode.align <= align;
            decode.sel   <= sel;
            
            // WB controls
            decode.rd_write     <= regwr_rd_en;
            decode.rd           <= (regwr_rd_en) ? rd : '0;
            decode.branch       <= 1'b0;
            decode.branch_cond  <= 1'b0;
            decode.ld_size      <= 2'b0;
            decode.ld_sign      <= 1'b0;
            decode.st           <= 1'b0;
            decode.illegal      <= ~(instr_valid) | illegal_opcode;

            // Store defaults in operands
            decode.op1 <= PC;
            decode.op2 <= FOUR;
            decode.op3 <= PC;
            decode.op4 <= ZERO;

            // Fill out OP1-4 as per opcode
            /* verilator lint_off CASEINCOMPLETE */
            case(OP)
                INSTR_LUI   : begin
                    decode.op1 <= ZERO;
                    decode.op2 <= immediate;
                end
                INSTR_AUIPC : begin
                    decode.op2 <= immediate;
                end
                INSTR_OPIMM : begin
                    decode.op1 <= regrd_rs1;
                    decode.op2 <= immediate;
                    decode.op1_regrd <= 1'b1;
                end
                INSTR_OP    : begin
                    decode.op1 <= regrd_rs1;
                    decode.op2 <= regrd_rs2;
                    decode.op1_regrd <= 1'b1;
                    decode.op2_regrd <= 1'b1;
                end
            endcase // tOP
            /* verilator lint_off CASEINCOMPLETE */

        end
        else if (pipe_out_vld && pipe_out_rdy) begin
            pipe_out_vld <= 1'b0;
        end
    end
end

// Pipethru can only happen in the ID1 state
assign pipe_in_rdy = ~pipe_out_vld | pipe_out_rdy;

endmodule
