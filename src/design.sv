`timescale 1ns/1ps

// ============================================================================
// fp_fpu: Top-level, selecciona sumador o multiplicador segun mode
// ============================================================================
module fp_fpu (
  input  logic        clk, rst, start,
  input  logic [31:0] a, b,
  input  logic        mode,
  output logic [31:0] out,
  output logic        done,
  output logic [3:0]  flags
);
  logic [31:0] out_add, out_mul;
  logic        done_add, done_mul;
  logic [3:0]  flags_add, flags_mul;

  fp_adder u_add (
    .clk(clk), .rst(rst), .start(mode ? 1'b0 : start),
    .a(a), .b(b), .out(out_add), .done(done_add), .flags(flags_add)
  );
  fp_multiplier u_mul (
    .clk(clk), .rst(rst), .start(mode ? start : 1'b0),
    .a(a), .b(b), .out(out_mul), .done(done_mul), .flags(flags_mul)
  );

  assign out   = mode ? out_mul   : out_add;
  assign done  = mode ? done_mul  : done_add;
  assign flags = mode ? flags_mul : flags_add;
endmodule

// ============================================================================
// fp_multiplier: IEEE-754 SP con round-to-nearest-even y subnormales
// ============================================================================
module fp_multiplier (
  input  logic        clk, rst, start,
  input  logic [31:0] a, b,
  output logic [31:0] out,
  output logic        done,
  output logic [3:0]  flags
);
  typedef enum logic [2:0] {
    IDLE=3'd0, UNPACK=3'd1, MULTIPLY=3'd2, NORMALIZE=3'd3, PACK=3'd4
  } state_t;
  state_t cur, nxt;

  logic        sa, sb, sr;
  logic [7:0]  ea, eb;
  logic [22:0] ma, mb;
  logic [23:0] ma_e, mb_e;
  logic [47:0] prod;
  logic [9:0]  exp_tmp;             // ea+eb-127, 10 bits (range -127..381)
  logic signed [9:0] exp_nrm;       // exponente despues de normalizar (10-bit signed)
  logic [22:0] mant_r;
  logic        guard_m, sticky_m;

  assign sa = a[31]; assign ea = a[30:23]; assign ma = a[22:0];
  assign sb = b[31]; assign eb = b[30:23]; assign mb = b[22:0];

  logic iza, izb, iia, iib, ina, inb;
  assign iza = (ea==8'h00)&&(ma==23'h0);
  assign izb = (eb==8'h00)&&(mb==23'h0);
  assign iia = (ea==8'hFF)&&(ma==23'h0);
  assign iib = (eb==8'hFF)&&(mb==23'h0);
  assign ina = (ea==8'hFF)&&(ma!=23'h0);
  assign inb = (eb==8'hFF)&&(mb!=23'h0);

  // Redondeo combinacional (round-to-nearest-even)
  wire        rnd_up  = guard_m & (sticky_m | mant_r[0]);
  wire [22:0] mnt_rnd = mant_r + {22'h0, rnd_up};
  wire        mnt_ovf = (mant_r == 23'h7FFFFF) & rnd_up;
  wire [22:0] mnt_fin = mnt_ovf ? 23'h0 : mnt_rnd;

  // Exponente final para numero normal (con carry de redondeo)
  wire signed [9:0] exp_fin = exp_nrm + $signed({9'h0, mnt_ovf});

  // Subnormal: sub_sh = 1 - exp_nrm (cuantos bits desplazar a la derecha)
  wire signed [9:0] sub_sh_s  = 10'sd1 - exp_nrm;
  wire [5:0]        sub_sh    = sub_sh_s[5:0];  // safe: only used when exp_nrm <= 0
  wire              sub_flush = (sub_sh_s >= 10'sd24);
  wire [23:0]       sub_mant  = {1'b1, mnt_fin} >> sub_sh;

  // Redondeo round-to-nearest-even para resultado subnormal
  wire [5:0]  sub_sh_m1   = (sub_sh >= 6'd1) ? sub_sh - 6'd1 : 6'd0;
  wire [23:0] sub_ext      = {1'b1, mnt_fin} >> sub_sh_m1;   // shifted by sub_sh-1
  wire        guard_sub    = (sub_sh >= 6'd1) ? sub_ext[0] : 1'b0;
  wire [23:0] stick_mask   = (sub_sh >= 6'd2) ? ((24'h1 << sub_sh_m1) - 24'h1) : 24'h0;
  wire        sticky_sub   = |({1'b1, mnt_fin} & stick_mask);
  wire        sub_rnd      = guard_sub & (sticky_sub | sub_mant[0]);
  wire [22:0] sub_mant_rd  = sub_mant[22:0] + {22'h0, sub_rnd};
  wire        sub_rnd_ovf  = (&sub_mant[22:0]) & sub_rnd;   // todos 1s + rnd = sube a normal

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      cur<=IDLE; done<=0; out<=0; flags<=0;
      sr<=0; mant_r<=0; exp_tmp<=0; exp_nrm<=0;
      ma_e<=0; mb_e<=0; prod<=0; guard_m<=0; sticky_m<=0;
    end else begin
      cur <= nxt;
      case (cur)
        IDLE: begin done<=0; flags<=0; end

        UNPACK: begin
          sr    <= sa ^ sb;
          ma_e  <= ea==8'h00 ? {1'b0,ma} : {1'b1,ma};
          mb_e  <= eb==8'h00 ? {1'b0,mb} : {1'b1,mb};
          exp_tmp <= {1'b0, {1'b0,ea}} + {1'b0, {1'b0,eb}} - 10'd127;
        end

        MULTIPLY: begin
          prod <= ma_e * mb_e;
        end

        NORMALIZE: begin
          if (prod[47]) begin
            mant_r   <= prod[46:24];
            guard_m  <= prod[23];
            sticky_m <= |prod[22:0];
            exp_nrm  <= $signed(exp_tmp) + 10'sd1;
          end else if (prod[46]) begin
            mant_r   <= prod[45:23];
            guard_m  <= prod[22];
            sticky_m <= |prod[21:0];
            exp_nrm  <= $signed(exp_tmp);
          end else begin
            mant_r   <= prod[44:22];
            guard_m  <= prod[21];
            sticky_m <= |prod[20:0];
            exp_nrm  <= $signed(exp_tmp) - 10'sd1;
          end
        end

        PACK: begin
          if (iza || izb) begin
            out <= {sr, 31'h0};

          end else if (ina || inb) begin
            out <= 32'h7FC00000; flags[3] <= 1'b1;

          end else if (iia || iib) begin
            out <= {sr, 8'hFF, 23'h0};

          end else if (exp_fin >= 10'sd255) begin
            out <= {sr, 8'hFF, 23'h0}; flags[2] <= 1'b1;  // overflow → ±inf

          end else if (exp_nrm <= 10'sd0) begin
            // Subnormal o underflow con redondeo round-to-nearest-even
            if (sub_flush) begin
              out <= {sr, 31'h0}; flags[1] <= 1'b1;
            end else if (sub_rnd_ovf) begin
              // Redondeo de subnormal sube al menor numero normal
              out <= {sr, 8'h01, 23'h0};
            end else begin
              out <= {sr, 8'h00, sub_mant_rd};
              if (sub_mant_rd == 23'h0) flags[1] <= 1'b1;
            end

          end else begin
            out <= {sr, exp_fin[7:0], mnt_fin};
          end
          done <= 1'b1;
        end
      endcase
    end
  end

  always_comb begin
    case (cur)
      IDLE:      if (start) nxt = UNPACK; else nxt = IDLE;
      UNPACK:    nxt = MULTIPLY;
      MULTIPLY:  nxt = NORMALIZE;
      NORMALIZE: nxt = PACK;
      PACK:      nxt = IDLE;
      default:   nxt = IDLE;
    endcase
  end
endmodule

// ============================================================================
// fp_adder: IEEE-754 SP con guard bit + sticky correctos para R-N-E
// ============================================================================
module fp_adder (
  input  logic        clk, rst, start,
  input  logic [31:0] a, b,
  output logic [31:0] out,
  output logic        done,
  output logic [3:0]  flags
);
  typedef enum logic [2:0] {
    IDLE=3'd0, UNPACK=3'd1, ALIGN=3'd2, ADD_SUB=3'd3, NORMALIZE=3'd4, PACK=3'd5
  } state_t;
  state_t cur, nxt;

  logic        sa, sb, sr;
  logic [7:0]  ea, eb, exp_com, exp_r;
  logic [22:0] ma, mb, mant_r;
  logic [23:0] ma_e, mb_e, ma_al, mb_al;
  logic [24:0] add_res;
  logic [7:0]  ediff;
  logic        sub_op;
  logic        guard_a;    // primer bit descartado en alineamiento
  logic        sticky_a;   // OR de bits restantes descartados

  assign sa = a[31]; assign ea = a[30:23]; assign ma = a[22:0];
  assign sb = b[31]; assign eb = b[30:23]; assign mb = b[22:0];

  logic iza,izb,iia,iib,ina,inb;
  assign iza=(ea==8'h00)&&(ma==23'h0); assign izb=(eb==8'h00)&&(mb==23'h0);
  assign iia=(ea==8'hFF)&&(ma==23'h0); assign iib=(eb==8'hFF)&&(mb==23'h0);
  assign ina=(ea==8'hFF)&&(ma!=23'h0); assign inb=(eb==8'hFF)&&(mb!=23'h0);

  // ── Redondeo combinacional para el sumador ──────────────────────────────
  // Condicion de redondeo (misma para suma y resta, accion diferente)
  // Suma:  add_res demasiado pequeno → sumar rnd
  // Resta: add_res demasiado grande  → restar rnd
  wire rnd_cond = guard_a & (sticky_a | add_res[0]);

  // Caso add_res[24]=1 (overflow de suma, solo sub_op=0)
  wire rnd24   = add_res[0] & (sticky_a | add_res[1]);
  wire [22:0] mnt24 = add_res[23:1] + {22'h0, rnd24};
  wire        ovf24 = (add_res[23:1]==23'h7FFFFF) & rnd24;

  // Caso add_res[23]=1: suma sube, resta baja
  wire [22:0] mnt23_add = add_res[22:0] + {22'h0, rnd_cond};   // addition
  wire [22:0] mnt23_sub = add_res[22:0] - {22'h0, rnd_cond};   // subtraction
  wire        ovf23_add = (add_res[22:0]==23'h7FFFFF) & rnd_cond;

  // Caso add_res[22]=1 (shift-left 1, sub_op=1):
  // guard_a esta a exactamente 1 ULP post-shift → restar guard_a
  wire [22:0] shift1_mant = {add_res[21:0], 1'b0};
  wire        shift1_borrow = (add_res[21:0] == 22'h0) & guard_a;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      cur<=IDLE; done<=0; out<=0; flags<=0;
      sr<=0; exp_com<=0; exp_r<=0; mant_r<=0;
      ma_e<=0; mb_e<=0; ma_al<=0; mb_al<=0;
      add_res<=0; ediff<=0; sub_op<=0;
      guard_a<=0; sticky_a<=0;
    end else begin
      cur <= nxt;
      case (cur)
        IDLE: begin done<=0; flags<=0; end

        UNPACK: begin
          ma_e    <= ea==8'h00 ? {1'b0,ma} : {1'b1,ma};
          mb_e    <= eb==8'h00 ? {1'b0,mb} : {1'b1,mb};
          sub_op  <= (sa != sb);
          if (ea >= eb) begin
            exp_com <= ea; ediff <= ea - eb;
          end else begin
            exp_com <= eb; ediff <= eb - ea;
          end
        end

        ALIGN: begin
          exp_r <= exp_com;
          if (ea >= eb) begin
            ma_al <= ma_e;
            if (ediff == 8'd0) begin
              mb_al    <= mb_e;
              guard_a  <= 1'b0;
              sticky_a <= 1'b0;
            end else if (ediff >= 8'd25) begin
              mb_al    <= 24'h0;
              guard_a  <= 1'b0;
              sticky_a <= |mb_e;
            end else begin
              mb_al    <= mb_e >> ediff;
              // guard = bit[ediff-1] de mb_e = (mb_e >> (ediff-1)) & 1
              guard_a  <= (mb_e >> (ediff - 8'd1)) & 1'b1;
              // sticky = OR de bits[ediff-2:0]
              sticky_a <= (ediff > 8'd1) ? |(mb_e & ((24'd1 << (ediff-8'd1)) - 24'd1)) : 1'b0;
            end
          end else begin
            mb_al <= mb_e;
            if (ediff == 8'd0) begin
              ma_al    <= ma_e;
              guard_a  <= 1'b0;
              sticky_a <= 1'b0;
            end else if (ediff >= 8'd25) begin
              ma_al    <= 24'h0;
              guard_a  <= 1'b0;
              sticky_a <= |ma_e;
            end else begin
              ma_al    <= ma_e >> ediff;
              guard_a  <= (ma_e >> (ediff - 8'd1)) & 1'b1;
              sticky_a <= (ediff > 8'd1) ? |(ma_e & ((24'd1 << (ediff-8'd1)) - 24'd1)) : 1'b0;
            end
          end
        end

        ADD_SUB: begin
          if (!sub_op) begin
            add_res <= ma_al + mb_al;
            sr      <= sa;
          end else begin
            if (ma_al >= mb_al) begin
              add_res <= ma_al - mb_al;
              sr      <= sa;
            end else begin
              add_res <= mb_al - ma_al;
              sr      <= sb;
            end
          end
        end

        NORMALIZE: begin
          if (add_res[24]) begin
            // Overflow de suma: shift right 1, aplicar redondeo
            exp_r <= exp_r + 1'b1;
            if (ovf24) begin
              mant_r <= 23'h0;
              exp_r  <= exp_r + 8'd2;
            end else begin
              mant_r <= mnt24;
            end

          end else if (add_res[23]) begin
            // Resultado normalizado: redondear segun direccion de la operacion
            if (!sub_op) begin
              // Suma: guard aumenta el resultado → round up
              if (ovf23_add) begin mant_r <= 23'h0; exp_r <= exp_r + 1'b1;
              end else begin mant_r <= mnt23_add; end
            end else begin
              // Resta: guard disminuye el resultado → round down (restar)
              mant_r <= mnt23_sub;
            end

          end else if (add_res == 25'b0) begin
            mant_r <= 23'h0;
            exp_r  <= 8'h00;

          end else begin
            // Shift left para normalizar
            if (add_res[22]) begin
              // Shift 1: para resta, guard_a = exactamente 1 ULP post-shift → restar
              exp_r <= exp_r - 8'd1;
              if (sub_op && guard_a) begin
                if (shift1_borrow) begin
                  mant_r <= 23'h7FFFFF; exp_r <= exp_r - 8'd2;
                end else begin
                  mant_r <= shift1_mant - 23'd1;
                end
              end else begin
                mant_r <= shift1_mant;
              end
            end
            else if (add_res[21]) begin mant_r <= {add_res[20:0], 2'b0};  exp_r <= exp_r - 8'd2; end
            else if (add_res[20]) begin mant_r <= {add_res[19:0], 3'b0};  exp_r <= exp_r - 8'd3; end
            else if (add_res[19]) begin mant_r <= {add_res[18:0], 4'b0};  exp_r <= exp_r - 8'd4; end
            else if (add_res[18]) begin mant_r <= {add_res[17:0], 5'b0};  exp_r <= exp_r - 8'd5; end
            else if (add_res[17]) begin mant_r <= {add_res[16:0], 6'b0};  exp_r <= exp_r - 8'd6; end
            else if (add_res[16]) begin mant_r <= {add_res[15:0], 7'b0};  exp_r <= exp_r - 8'd7; end
            else if (add_res[15]) begin mant_r <= {add_res[14:0], 8'b0};  exp_r <= exp_r - 8'd8; end
            else if (add_res[14]) begin mant_r <= {add_res[13:0], 9'b0};  exp_r <= exp_r - 8'd9; end
            else if (add_res[13]) begin mant_r <= {add_res[12:0],10'b0};  exp_r <= exp_r - 8'd10; end
            else if (add_res[12]) begin mant_r <= {add_res[11:0],11'b0};  exp_r <= exp_r - 8'd11; end
            else if (add_res[11]) begin mant_r <= {add_res[10:0],12'b0};  exp_r <= exp_r - 8'd12; end
            else if (add_res[10]) begin mant_r <= {add_res[ 9:0],13'b0};  exp_r <= exp_r - 8'd13; end
            else if (add_res[ 9]) begin mant_r <= {add_res[ 8:0],14'b0};  exp_r <= exp_r - 8'd14; end
            else if (add_res[ 8]) begin mant_r <= {add_res[ 7:0],15'b0};  exp_r <= exp_r - 8'd15; end
            else if (add_res[ 7]) begin mant_r <= {add_res[ 6:0],16'b0};  exp_r <= exp_r - 8'd16; end
            else if (add_res[ 6]) begin mant_r <= {add_res[ 5:0],17'b0};  exp_r <= exp_r - 8'd17; end
            else if (add_res[ 5]) begin mant_r <= {add_res[ 4:0],18'b0};  exp_r <= exp_r - 8'd18; end
            else if (add_res[ 4]) begin mant_r <= {add_res[ 3:0],19'b0};  exp_r <= exp_r - 8'd19; end
            else if (add_res[ 3]) begin mant_r <= {add_res[ 2:0],20'b0};  exp_r <= exp_r - 8'd20; end
            else if (add_res[ 2]) begin mant_r <= {add_res[ 1:0],21'b0};  exp_r <= exp_r - 8'd21; end
            else if (add_res[ 1]) begin mant_r <= {add_res[0],   22'b0};  exp_r <= exp_r - 8'd22; end
            else                  begin mant_r <= 23'h0; exp_r <= 8'h00; end
          end
        end

        PACK: begin
          if      (ina || inb)                    begin out<=32'h7FC00000; flags[3]<=1; end
          else if (iia&&iib&&sub_op)              begin out<=32'h7FC00000; flags[3]<=1; end
          else if (iia)                           begin out<=a; end
          else if (iib)                           begin out<=sub_op?{~sb,b[30:0]}:b; end
          else if (iza&&izb)                      begin out<={sa&sb,31'h0}; end
          else if (iza)                           begin out<=sub_op?{~sb,b[30:0]}:b; end
          else if (izb)                           begin out<=a; end
          else if (add_res==25'b0)                begin out<=32'h0; end
          else if (exp_r>=8'hFF)                  begin out<={sr,8'hFF,23'h0}; flags[2]<=1; end
          else if (exp_r==8'h00)                  begin out<={sr,8'h00,23'h0}; flags[1]<=1; end
          else                                    begin out<={sr,exp_r,mant_r}; end
          done <= 1'b1;
        end
      endcase
    end
  end

  always_comb begin
    case (cur)
      IDLE:      if (start) nxt = UNPACK; else nxt = IDLE;
      UNPACK:    nxt = ALIGN;
      ALIGN:     nxt = ADD_SUB;
      ADD_SUB:   nxt = NORMALIZE;
      NORMALIZE: nxt = PACK;
      PACK:      nxt = IDLE;
      default:   nxt = IDLE;
    endcase
  end
endmodule
