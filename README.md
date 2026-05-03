# Sumador/Multiplicador de Punto Flotante IEEE-754 — Ambiente de Verificación

Proyecto desarrollado para el curso **EL-5521 Verificación Funcional de Circuitos Integrados** del Instituto Tecnológico de Costa Rica (TEC), I semestre 2025.

Implementa una FPU (Floating Point Unit) de precisión simple (32 bits) en SystemVerilog con cumplimiento pleno del estándar IEEE-754, junto con un ambiente de verificación completo que alcanza **100% de los casos de prueba**.

---

## Resultado final

```
Pruebas exitosas: 213 / 213
Pruebas fallidas:   0
Tasa de éxito:  100.00%
Simulador:      Aldec Riviera-PRO 2025.04
```

---

## Arquitectura del DUT

El módulo `fp_fpu` integra un sumador y un multiplicador de punto flotante seleccionados por la señal `mode`.

```
fp_fpu (top)
├── fp_adder      — Suma/resta IEEE-754 SP (FSM 6 estados)
└── fp_multiplier — Multiplicación IEEE-754 SP (FSM 5 estados)
```

### Interfaz

| Señal   | Dir    | Bits | Descripción                              |
|---------|--------|------|------------------------------------------|
| `clk`   | input  | 1    | Reloj                                    |
| `rst`   | input  | 1    | Reset síncrono activo en alto            |
| `start` | input  | 1    | Pulso de inicio de operación             |
| `a`     | input  | 32   | Operando A (IEEE-754 SP)                 |
| `b`     | input  | 32   | Operando B (IEEE-754 SP)                 |
| `mode`  | input  | 1    | `0` = suma/resta, `1` = multiplicación   |
| `out`   | output | 32   | Resultado (IEEE-754 SP)                  |
| `done`  | output | 1    | Pulso de resultado listo                 |
| `flags` | output | 4    | `[3]`=NaN `[2]`=OVF `[1]`=UNF           |

### Casos especiales soportados

| Caso | Resultado |
|------|-----------|
| ±0 × cualquier | ±0 |
| ±∞ + finito | ±∞ |
| ∞ − ∞ | NaN |
| NaN + cualquier | NaN |
| Overflow de exponente | ±∞ + flag OVF |
| Underflow de exponente | ±0 + flag UNF |
| Números subnormales | Soportados con R-N-E |

---

## Implementación IEEE-754

Ambos módulos implementan **round-to-nearest-even** (R-N-E) completo con bits de guarda y sticky.

### fp_multiplier

FSM: `IDLE → UNPACK → MULTIPLY → NORMALIZE → PACK`

- Multiplicación de mantisas 24×24 con producto de 48 bits
- Guard + sticky bits extraídos del producto para R-N-E
- Exponente con 10 bits signed para rango completo (-127 a +381)
- Números subnormales con shift calculado desde `exp_nrm` y R-N-E propio

### fp_adder

FSM: `IDLE → UNPACK → ALIGN → ADD_SUB → NORMALIZE → PACK`

- Alineamiento con guard + sticky guardados por separado
- **Redondeo diferenciado por dirección de operación:**
  - Suma: guard bits aumentan el resultado → redondear hacia arriba
  - Resta: guard bits disminuyen el resultado → redondear hacia abajo
- Normalización por shift-left hasta 23 posiciones
- Para shift-left de 1 posición en resta: guard representa exactamente 1 ULP

---

## Ambiente de Verificación (`tb/testbench.sv`)

Implementa un ambiente modular en SystemVerilog siguiendo el patrón estándar de la industria (UVM-like), con separación clara de responsabilidades entre componentes.

### Diagrama del ambiente

```
┌──────────────────────────────────────────────────────────────┐
│                      fp_fpu_tb (Top)                         │
│                                                              │
│  ┌─────────────────┐       ┌──────────────────────────────┐  │
│  │   FPU_Tester    │──────▶│         fpu_if               │  │
│  │                 │       │   (Interface tipada con       │  │
│  │ rand operand_a  │       │    modports tb / dut)         │  │
│  │ rand operand_b  │       └────────────┬─────────────┬───┘  │
│  │ constraint {...} │                   │ estímulos   │ done  │
│  │ get_expected()  │              ┌─────▼─────┐       │      │
│  └─────────────────┘              │  fp_fpu   │       │      │
│                                   │   (DUT)   │       │      │
│  ┌─────────────────┐              └─────┬─────┘       │      │
│  │  FPU_Monitor    │◀────────────────────────────────┘      │
│  │                 │   observa done + resultado              │
│  │ observe()       │                                         │
│  └────────┬────────┘                                         │
│           │ FPU_Transaction                                  │
│           │ {op_a, op_b, mode,                               │
│           │  result, flags, timestamp}                       │
│           │                                                  │
│  ┌────────▼────────┐      ┌──────────────────────────────┐  │
│  │ FPU_Scoreboard  │      │       fpu_coverage           │  │
│  │                 │      │                              │  │
│  │ check_          │      │  cp_operation  cp_sign_a     │  │
│  │ transaction()   │      │  cp_sign_b     cp_special    │  │
│  │ golden model    │      │  cross_op_signs              │  │
│  │ → log file      │      └──────────────────────────────┘  │
│  └─────────────────┘                                         │
└──────────────────────────────────────────────────────────────┘
```

### Flujo de datos

```
Tester ──▶ fpu_if ──▶ DUT ──▶ Monitor ──▶ FPU_Transaction ──▶ Scoreboard
                              (done)                       └──▶ CoverGroup
```

### `fpu_if` — Interface
Bus tipado con modports `tb` y `dut` que centraliza todas las señales entre el tester y el DUT. Punto único de conexión que facilita cambios de protocolo.

### `FPU_Transaction` — Clase de datos
Encapsula una operación completa de la FPU. Es el objeto que circula entre Monitor, Scoreboard y CoverGroup, desacoplando la observación del bus de la verificación.

```systemverilog
class FPU_Transaction;
  bit [31:0] op_a, op_b, result;
  bit        mode;
  bit [3:0]  flags;
  time       timestamp;
  function string to_string();
endclass
```

### `FPU_Tester` — Clase con randomización
Genera estímulos aleatorios con constraints y calcula el resultado esperado mediante el golden model nativo del simulador.

```systemverilog
class FPU_Tester;
  rand bit [31:0] operand_a, operand_b;
  rand bit        operation;
  constraint valid_test_cases { ... }  // 60% normales, 20% especiales, 20% conocidos
  static function bit is_special_case(...);
  function bit [31:0] get_expected_result();  // usa $bitstoshortreal
endclass
```

### `FPU_Monitor` — Clase de observación pasiva
Observa la interface sin modificar ninguna señal. Detecta cuando `done=1`, empaqueta el resultado en un `FPU_Transaction` y lo entrega al Scoreboard. Es el único componente que conoce el protocolo de finalización del DUT.

```systemverilog
class FPU_Monitor;
  virtual fpu_if vif;
  task automatic observe(input bit [31:0] a, b, input bit mode,
                         output FPU_Transaction tr);
endclass
```

### `FPU_Scoreboard` — Clase con golden model
Recibe `FPU_Transaction` del Monitor, compara con el valor esperado del Tester y registra PASS/FAIL. Genera el archivo de log y el reporte final.

### `fpu_coverage` — Covergroup
```systemverilog
covergroup fpu_coverage;
    cp_operation: coverpoint vif.mode iff (vif.start);
    cp_sign_a:    coverpoint vif.a[31] iff (vif.start);
    cp_sign_b:    coverpoint vif.b[31] iff (vif.start);
    cp_exp_a/b:   coverpoint exp { bins zero, normal, special, others }
    cross_op_signs: cross cp_operation, cp_sign_a, cp_sign_b;
endgroup
```

---

## Estructura del repositorio

```
fp_fpu/
├── src/
│   └── design.sv        # DUT: fp_fpu, fp_adder, fp_multiplier
├── tb/
│   └── testbench.sv     # Interface, Tester, Scoreboard, Covergroups
├── run.sh               # Instrucciones de simulación
├── .gitignore
└── README.md
```

---

## Simulación

El testbench requiere un simulador full-SystemVerilog (`class`, `rand`, `covergroup`).

### EDA Playground (recomendado — gratuito)

1. Ir a [edaplayground.com](https://edaplayground.com)
2. Seleccionar **Aldec Riviera-PRO**
3. Compile Options: `-timescale 1ns/1ps`
4. Pegar `design.sv` en Design y `testbench.sv` en Testbench
5. Click **Run**

### Verificación local con iverilog

```bash
# Solo verifica que el DUT compila correctamente
iverilog -g2012 -o /tmp/fpu_check src/design.sv && echo "DUT OK"
```

---

## Evolución del desarrollo

| Versión | PASS | % | Mejora |
|---------|------|---|--------|
| Original | 101/213 | 47% | Código base |
| v1 | 138/213 | 65% | Underflow, normalización 23 shifts |
| v2 | 151/213 | 71% | R-N-E básico multiplicador |
| v3 | 194/213 | 91% | Guard+sticky, subnormales, exp signed 10-bit |
| v4 | 208/213 | 97.7% | Redondeo diferenciado suma/resta |
| **v5** | **213/213** | **100%** | R-N-E completo en path subnormal |

---

## Autor

Sergio Zapata — Instituto Tecnológico de Costa Rica
Curso: EL-5521 Verificación Funcional de Circuitos Integrados, I semestre 2025
