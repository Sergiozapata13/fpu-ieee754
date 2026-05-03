// testbench.sv 
`timescale 1ns/1ps

// Interface para el DUT
interface fpu_if (input logic clk);
  logic        rst, start;
  logic [31:0] a, b;
  logic        mode;
  logic [31:0] out;
  logic        done;
  logic [3:0]  flags;
  
  modport tb (output rst, start, a, b, mode, input out, done, flags, input clk);
  modport dut (input rst, start, a, b, mode, output out, done, flags, input clk);
endinterface

// Clase Tester con métodos estaticos
class FPU_Tester;
  rand bit [31:0] operand_a;
  rand bit [31:0] operand_b;
  rand bit        operation;
  
  // Constraints para casos mas diversos
  constraint valid_test_cases {
    // 60% numeros normales, 20% casos especiales, 20% valores conocidos
    operand_a[30:23] dist {
      8'h00 := 5,           // Zero
      [8'h01:8'h7E] := 60,  // Numeros normales
      8'h7F := 15,          // Numeros cercanos a 1.0
      [8'h80:8'hFE] := 15,  // Numeros grandes
      8'hFF := 5            // Infinito/NaN
    };
    
    operand_b[30:23] dist {
      8'h00 := 5,           // Zero
      [8'h01:8'h7E] := 60,  // Numeros normales
      8'h7F := 15,          // Numeros cercanos a 1.0
      [8'h80:8'hFE] := 15,  // Numeros grandes
      8'hFF := 5            // Infinito/NaN
    };
    
    operation dist {0 := 50, 1 := 50};
  }
  
  // Metodo estatico
  static function bit is_special_case(bit [31:0] val);
    return (val[30:23] == 8'h00) || (val[30:23] == 8'hFF);
  endfunction
  
  // Lookup tables
  function automatic bit [31:0] real_to_bits(input real r);
    case (r)
      0.0:   return 32'h00000000;
      1.0:   return 32'h3F800000;
      2.0:   return 32'h40000000;
      3.0:   return 32'h40400000;
      4.0:   return 32'h40800000;
      1.5:   return 32'h3FC00000;
      2.25:  return 32'h40100000;
      3.75:  return 32'h40700000;
      -1.0:  return 32'hBF800000;
      -2.0:  return 32'hC0000000;
      default: return 32'h00000000;
    endcase
  endfunction

  function automatic real bits_to_real(input bit [31:0] bits);
    case (bits)
      32'h00000000: return 0.0;
      32'h3F800000: return 1.0;
      32'h40000000: return 2.0;
      32'h40400000: return 3.0;
      32'h40800000: return 4.0;
      32'h3FC00000: return 1.5;
      32'h40100000: return 2.25;
      32'h40700000: return 3.75;
      32'hBF800000: return -1.0;
      32'hC0000000: return -2.0;
      default: return 0.0;
    endcase
  endfunction
  
  // Modelo de referencia 
  function automatic bit [31:0] get_expected_result();
    real ra, rb, result;
    
    // Funciones built-in para conversion real
    ra = $bitstoshortreal(operand_a);
    rb = $bitstoshortreal(operand_b);
    
    // Casos especiales IEEE-754
    if ((operand_a[30:23] == 8'hFF && operand_a[22:0] != 0) || 
        (operand_b[30:23] == 8'hFF && operand_b[22:0] != 0)) begin
      return 32'h7FC00000; // NaN
    end
    
    if (operand_a[30:23] == 8'hFF && operand_a[22:0] == 0) begin
      if (operation == 0) begin
        if (operand_b[30:23] == 8'hFF && operand_b[22:0] == 0 && operand_a[31] != operand_b[31])
          return 32'h7FC00000; // +inf + -inf = NaN
        else
          return operand_a; // inf + anything = inf
      end else begin
        if (operand_b == 32'h00000000 || operand_b == 32'h80000000)
          return 32'h7FC00000; // inf * 0 = NaN
        else
          return {operand_a[31] ^ operand_b[31], 8'hFF, 23'b0}; // inf * x = pm_inf
      end
    end
    
    if (operand_b[30:23] == 8'hFF && operand_b[22:0] == 0) begin
      if (operation == 0) begin
        return operand_b; // anything + inf = inf
      end else begin
        if (operand_a == 32'h00000000 || operand_a == 32'h80000000)
          return 32'h7FC00000; // 0 * inf = NaN
        else
          return {operand_a[31] ^ operand_b[31], 8'hFF, 23'b0}; // x * inf = pm_inf
      end
    end
    
    // Operaciones normales usando built-in
    if (operation == 0) result = ra + rb;  // Suma
    else result = ra * rb;                 // Multiplicacion
    
    // Usar funcion built-in para conversion de vuelta
    return $shortrealtobits(result);
  endfunction
endclass

// Clase Scoreboard
class FPU_Scoreboard;
  int unsigned total_tests = 0;
  int unsigned passed_tests = 0;
  int unsigned failed_tests = 0;
  int log_file;
  
  function new();
    log_file = $fopen("fpu_test_results.log", "w");
    if (log_file != 0) begin
      $fdisplay(log_file, "FPU TEST LOG");
      $fdisplay(log_file, "Timestamp: %t", $time);
    end
  endfunction
  
  function void record_test(
    input bit [31:0] op_a,
    input bit [31:0] op_b, 
    input bit        op,
    input bit [31:0] expected,
    input bit [31:0] actual,
    input bit [3:0]  test_flags,
    input bit        passed,
    input string     name
  );
    total_tests++;
    
    if (passed) begin
      passed_tests++;
      $display("[PASS] %s: %h %s %h = %h", 
               name, op_a, (op ? "*" : "+"), op_b, actual);
      if (log_file != 0) begin
        $fdisplay(log_file, "[PASS] %s: %h %s %h = %h", 
                  name, op_a, (op ? "*" : "+"), op_b, actual);
      end
    end else begin
      failed_tests++;
      $display("[FAIL] %s: %h %s %h = %h, expected %h", 
               name, op_a, (op ? "*" : "+"), op_b, actual, expected);
      if (log_file != 0) begin
        $fdisplay(log_file, "[FAIL] %s: %h %s %h = %h, expected %h", 
                  name, op_a, (op ? "*" : "+"), op_b, actual, expected);
      end
    end
  endfunction
  
  function void print_final_report();
    real success_rate;
    if (total_tests > 0) begin
      success_rate = (real'(passed_tests) / real'(total_tests)) * 100.0;
    end else begin
      success_rate = 0.0;
    end
    
    $display("-----------------REPORTE FINAL-----------------");
    $display("Total de pruebas: %d", total_tests);
    $display("Pruebas exitosas: %d", passed_tests);
    $display("Pruebas fallidas: %d", failed_tests);
    $display("Porcentaje de pruebas: %f%%", success_rate);
    
    if (log_file != 0) begin
      $fdisplay(log_file, "-----------------REPORTE FINAL-----------------");
      $fdisplay(log_file, "Total de pruebas: %d", total_tests);
      $fdisplay(log_file, "Pruebas exitosas: %d", passed_tests);
      $fdisplay(log_file, "Pruebas fallidas: %d", failed_tests);
      $fdisplay(log_file, "Porcentaje de pruebas: %f%%", success_rate);
      $fclose(log_file);
    end
    
    if (failed_tests == 0) begin
      $display("ALL TESTS PASSED!");
    end else begin
      $display("%d tests failed", failed_tests);
    end
  endfunction
endclass

module fp_fpu_tb;

  // Clock generation
  logic clk = 0;
  always #5 clk = ~clk;

  // Interface instance
  fpu_if vif(clk);

  // DUT instance
  fp_fpu dut (
    .clk   (vif.clk),
    .rst   (vif.rst),
    .start (vif.start),
    .a     (vif.a),
    .b     (vif.b),
    .mode  (vif.mode),
    .out   (vif.out),
    .done  (vif.done),
    .flags (vif.flags)
  );

  // Coverage manual 
  int coverage_add_ops = 0;
  int coverage_mul_ops = 0;
  int coverage_pos_signs = 0;
  int coverage_neg_signs = 0;
  int coverage_zero_exp = 0;
  int coverage_normal_exp = 0;
  int coverage_special_exp = 0;

  // Class instances
  FPU_Tester      tester;
  FPU_Scoreboard  scoreboard;

  // Cover Groups 
  covergroup fpu_coverage;
    option.per_instance = 1;
    option.at_least = 1;
    
    cp_operation: coverpoint vif.mode iff (vif.start) {
      bins add = {0};
      bins mul = {1};
    }
    
    cp_exp_a: coverpoint vif.a[30:23] iff (vif.start) {
      bins zero     = {8'h00};
      bins normal   = {8'h7F};
      bins special  = {8'hFF};
      bins others   = default;
    }
    
    cp_exp_b: coverpoint vif.b[30:23] iff (vif.start) {
      bins zero     = {8'h00};
      bins normal   = {8'h7F};
      bins special  = {8'hFF};
      bins others   = default;
    }
    
    cp_sign_a: coverpoint vif.a[31] iff (vif.start) {
      bins positive = {0};
      bins negative = {1};
    }
    
    cp_sign_b: coverpoint vif.b[31] iff (vif.start) {
      bins positive = {0};
      bins negative = {1};
    }
    
    // Cross coverage
    cross_op_signs: cross cp_operation, cp_sign_a, cp_sign_b;
  endgroup

  // Instancia del covergroup
  fpu_coverage cov;
  
  // Variable para coverage 
  real actual_coverage;
  
  // Manual coverage function
  function void update_manual_coverage(bit [31:0] a_val, bit [31:0] b_val, bit op);
    if (op == 0) coverage_add_ops++;
    else coverage_mul_ops++;
    
    if (a_val[31] == 0 || b_val[31] == 0) coverage_pos_signs++;
    if (a_val[31] == 1 || b_val[31] == 1) coverage_neg_signs++;
    
    if (a_val[30:23] == 8'h00 || b_val[30:23] == 8'h00) coverage_zero_exp++;
    if (a_val[30:23] == 8'h7F || b_val[30:23] == 8'h7F) coverage_normal_exp++;
    if (a_val[30:23] == 8'hFF || b_val[30:23] == 8'hFF) coverage_special_exp++;
  endfunction
  
  function real calculate_manual_coverage();
    // Coverage real basado en exito de pruebas unicamente
    if (scoreboard.total_tests > 0) begin
      return (real'(scoreboard.passed_tests) / real'(scoreboard.total_tests)) * 100.0;
    end else begin
      return 0.0;
    end
  endfunction

  // Reset task
  task automatic reset_dut();
    vif.rst = 1;
    vif.start = 0;
    vif.a = 0;
    vif.b = 0;
    vif.mode = 0;
    repeat(5) @(posedge clk);
    vif.rst = 0;
    repeat(2) @(posedge clk);
    $display("Reset completed");
  endtask

  // Test execution task
  task automatic run_test(
    input bit [31:0] val_a,
    input bit [31:0] val_b,
    input bit        operation,
    input string     test_name
  );
    bit [31:0] expected;
    bit        test_passed;
    
    tester.operand_a = val_a;
    tester.operand_b = val_b;
    tester.operation = operation;
    expected = tester.get_expected_result();
    
    vif.a = val_a;
    vif.b = val_b;
    vif.mode = operation;
    
    @(posedge clk);
    vif.start = 1;
    
    // Coverage sampling 
    cov.sample();
    update_manual_coverage(val_a, val_b, operation);
    
    @(posedge clk);
    vif.start = 0;
    
    // Timeout por prueba: si done no llega en 5000ns se reporta error
    fork
      wait(vif.done);
      begin
        #5000;
        $display("[TIMEOUT] Prueba '%s' supero el limite de tiempo", test_name);
      end
    join_any
    disable fork;
    @(posedge clk);
    
    test_passed = (vif.out === expected);
    scoreboard.record_test(val_a, val_b, operation, expected, vif.out, vif.flags, test_passed, test_name);
    
    repeat(2) @(posedge clk);
  endtask

  // Pruebas del Main
  initial begin
    // Inicializar clases
    tester = new();
    scoreboard = new();
    cov = new();
    
    $display("AMBIENTE DE VERIFICACION PARA MODULO SUMADOR/MULTIPLICADOR DE PUNTO FLOTANTE.");
    $display("Classes: ENABLED");
    $display("Cover Groups: ENABLED"); 
    $display("Interfaces: ENABLED");
    $display("Log Files: ENABLED");
    
    reset_dut();
    
    $display("-------------------PRUEBAS DIRIGIDAS-----------------");
    
    // Pruebas dirigidas
    run_test(32'h3F800000, 32'h3F800000, 1'b0, "1p0_plus_1p0");
    run_test(32'h40000000, 32'h40000000, 1'b0, "2p0_plus_2p0");
    run_test(32'h3FC00000, 32'h40100000, 1'b0, "1p5_plus_2p25");
    run_test(32'h00000000, 32'h3F800000, 1'b0, "0p0_plus_1p0");
    run_test(32'hBF800000, 32'h3F800000, 1'b0, "neg1p0_plus_1p0");
    
    run_test(32'h3FC00000, 32'h40000000, 1'b1, "1p5_mult_2p0");
    run_test(32'h40000000, 32'h40000000, 1'b1, "2p0_mult_2p0");
    run_test(32'h00000000, 32'h3F800000, 1'b1, "0p0_mult_1p0");
    run_test(32'hBF800000, 32'h40000000, 1'b1, "neg1p0_mult_2p0");
    
    run_test(32'h3F800000, 32'h40400000, 1'b0, "1p0_plus_3p0");
    run_test(32'h3F800000, 32'h40000000, 1'b1, "1p0_mult_2p0");
    
    // Casos especiales
    run_test(32'h7F800000, 32'h3F800000, 1'b0, "plus_inf_plus_1p0");
    run_test(32'h7FC00000, 32'h3F800000, 1'b0, "NaN_plus_1p0");
    
    $display("-----------------PRUEBAS ALEATORIAS-----------------");
    
    // Pruebas aleatorias
    repeat(200) begin
      if (!tester.randomize()) begin
        $display("ERROR: Pruebas aleatorias fallidas");
        continue;
      end
      
      if (FPU_Tester::is_special_case(tester.operand_a) || 
          FPU_Tester::is_special_case(tester.operand_b)) begin
        $display("Special case detected in random test");
      end
      
      run_test(tester.operand_a, tester.operand_b, tester.operation, 
               (tester.operation ? "Random_MUL" : "Random_ADD"));
    end
    
    // Rerte Coverage y reporte final
    actual_coverage = calculate_manual_coverage();
    
    $display("-----------------VERIFICACION DE RESULTADOS-----------------");
    $display("Total de pruebas: %d", scoreboard.total_tests);
    $display("Pruebas exitosas: %d", scoreboard.passed_tests);
    $display("Pruebas fallidas: %d", scoreboard.failed_tests);
    $display("Tasa de exito: %f%%", actual_coverage);
    $display("Operaciones ADD: %d", coverage_add_ops);
    $display("Operaciones MUL: %d", coverage_mul_ops);
    $display("Valores positivos: %d", coverage_pos_signs);
    $display("Valores negativos: %d", coverage_neg_signs);
    $display("Casos especiales: %d", coverage_special_exp);
    
    // Reporte final
    scoreboard.print_final_report();
    
    $display("Simulacion completada");
    
    #100;
    $finish;
  end

  // Timeout
  initial begin
    #1000000;
    $display("ERROR: Tiempo de espera del simulador");
    $finish;
  end

endmodule