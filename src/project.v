`default_nettype none

module tt_um_piano (
    input  wire [7:0] ui_in,    // [6:0] Teclas blancas (Si..Do), [7] timbre[0]
    output wire [7:0] uo_out,   // [0] Audio Sigma-Delta, [7:1] Display 7-seg (g..a)
    input  wire [7:0] uio_in,   // [4:0] Teclas negras, [6:5] Octava, [7] timbre[1]
    output wire [7:0] uio_out,  // No usado (salidas en 0)
    output wire [7:0] uio_oe,   // Todos los uio configurados como entrada (0)
    input  wire       ena,      // Habilitación del diseño
    input  wire       clk,      // Reloj del sistema (10 MHz)
    input  wire       rst_n     // Reset activo en bajo
);

    assign uio_out = 8'b0000_0000;
    assign uio_oe  = 8'b0000_0000;

    wire [1:0] timbre = {uio_in[7], ui_in[7]};
    wire [1:0] octave = uio_in[6:5];

    // Vector ordenado cromáticamente de 0 (Do) a 11 (Si)
    wire [11:0] keys = {
        ui_in[6],   // 11: Si  (B)
        uio_in[4],  // 10: La# (A#)
        ui_in[5],   //  9: La  (A)
        uio_in[3],  //  8: Sol#(G#)
        ui_in[4],   //  7: Sol (G)
        uio_in[2],  //  6: Fa# (F#)
        ui_in[3],   //  5: Fa  (F)
        ui_in[2],   //  4: Mi  (E)
        uio_in[1],  //  3: Re# (D#)
        ui_in[1],   //  2: Re  (D)
        uio_in[0],  //  1: Do# (C#)
        ui_in[0]    //  0: Do  (C)
    };

    // =========================================================================
    // 1. ASIGNADOR DE 3 VOCES (Polifonía de 3 notas simultáneas)
    // =========================================================================
    reg [3:0] note1, note2, note3;
    reg       active1, active2, active3;
    integer   i;

    always @(*) begin
        note1   = 4'd0; active1 = 1'b0;
        note2   = 4'd0; active2 = 1'b0;
        note3   = 4'd0; active3 = 1'b0;

        // Voz 1: Primera tecla presionada (de grave a aguda)
        for (i = 0; i < 12; i = i + 1) begin
            if (keys[i] && !active1) begin
                note1   = i[3:0];
                active1 = 1'b1;
            end
        end

        // Voz 2: Segunda tecla distinta presionada
        for (i = 0; i < 12; i = i + 1) begin
            if (keys[i] && !active2 && (!active1 || (i[3:0] != note1))) begin
                note2   = i[3:0];
                active2 = 1'b1;
            end
        end

        // Voz 3: Tercera tecla distinta presionada
        for (i = 0; i < 12; i = i + 1) begin
            if (keys[i] && !active3 &&
               (!active1 || (i[3:0] != note1)) &&
               (!active2 || (i[3:0] != note2))) begin
                note3   = i[3:0];
                active3 = 1'b1;
            end
        end
    end

    // Detección de flanco de disparo para reiniciar envolvente al cambiar nota
    reg [3:0] prev_note1, prev_note2, prev_note3;
    reg       prev_act1, prev_act2, prev_act3;

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_note1 <= 4'd0; prev_note2 <= 4'd0; prev_note3 <= 4'd0;
            prev_act1  <= 1'b0; prev_act2  <= 1'b0; prev_act3  <= 1'b0;
        end else if (ena) begin
            prev_note1 <= note1; prev_note2 <= note2; prev_note3 <= note3;
            prev_act1  <= active1; prev_act2 <= active2; prev_act3 <= active3;
        end
    end

    wire trig1 = active1 && (!prev_act1 || (note1 != prev_note1));
    wire trig2 = active2 && (!prev_act2 || (note2 != prev_note2));
    wire trig3 = active3 && (!prev_act3 || (note3 != prev_note3));

    // =========================================================================
    // 2. TABLA DE INCREMENTOS DE FASE (Octava 2 @ 10 MHz, Acumulador 20 bits)
    // =========================================================================
    function [15:0] get_base_step;
        input [3:0] n;
        begin
            case (n)
                4'd0:  get_base_step = 16'd6858;  // C2  (65.41 Hz)
                4'd1:  get_base_step = 16'd7266;  // C#2 (69.30 Hz)
                4'd2:  get_base_step = 16'd7698;  // D2  (73.42 Hz)
                4'd3:  get_base_step = 16'd8156;  // D#2 (77.78 Hz)
                4'd4:  get_base_step = 16'd8641;  // E2  (82.41 Hz)
                4'd5:  get_base_step = 16'd9155;  // F2  (87.31 Hz)
                4'd6:  get_base_step = 16'd9699;  // F#2 (92.50 Hz)
                4'd7:  get_base_step = 16'd10276; // G2  (98.00 Hz)
                4'd8:  get_base_step = 16'd10887; // G#2 (103.83 Hz)
                4'd9:  get_base_step = 16'd11534; // A2  (110.00 Hz)
                4'd10: get_base_step = 16'd12220; // A#2 (116.54 Hz)
                4'd11: get_base_step = 16'd12947; // B2  (123.47 Hz)
                default: get_base_step = 16'd0;
            endcase
        end
    endfunction

    wire [19:0] step1 = {4'd0, get_base_step(note1)} << octave;
    wire [19:0] step2 = {4'd0, get_base_step(note2)} << octave;
    wire [19:0] step3 = {4'd0, get_base_step(note3)} << octave;

    // =========================================================================
    // 3. TRIPLE ACUMULADOR DE FASE (NCO de 20 bits x 3)
    // =========================================================================
    reg [19:0] phase1, phase2, phase3;

    always @(posedge clk) begin
        if (!rst_n) begin
            phase1 <= 20'd0;
            phase2 <= 20'd0;
            phase3 <= 20'd0;
        end else if (ena) begin
            phase1 <= active1 ? (phase1 + step1) : 20'd0;
            phase2 <= active2 ? (phase2 + step2) : 20'd0;
            phase3 <= active3 ? (phase3 + step3) : 20'd0;
        end
    end

    // =========================================================================
    // 4. GENERADOR DE FORMAS DE ONDA (4 Timbres por Voz)
    // =========================================================================
    function [7:0] shape_wave;
        input [19:0] ph;
        input [1:0]  tmb;
        reg [7:0] tri_w, tri_oct, piano_w, saw_w, sqr_w;
        begin
            tri_w   = ph[19] ? ~ph[18:11] : ph[18:11];
            tri_oct = ph[18] ? ~ph[17:10] : ph[17:10];
            piano_w = (tri_w >> 1) + (tri_w >> 2) + (tri_oct >> 2);
            saw_w   = ph[19:12];
            sqr_w   = ph[19] ? 8'hFF : 8'h00;

            case (tmb)
                2'b00: shape_wave = piano_w; // Piano Acústico
                2'b01: shape_wave = tri_w;   // Flauta
                2'b10: shape_wave = saw_w;   // Cuerdas
                2'b11: shape_wave = sqr_w;   // Retro 8-bit
            endcase
        end
    endfunction

    wire [7:0] raw_wave1 = shape_wave(phase1, timbre);
    wire [7:0] raw_wave2 = shape_wave(phase2, timbre);
    wire [7:0] raw_wave3 = shape_wave(phase3, timbre);

    // =========================================================================
    // 5. ENVOLVENTE SIN MULTIPLICADORES (3 Canales Independientes)
    // =========================================================================
    reg [15:0] env_tick_cnt;
    wire       env_tick = (env_tick_cnt == 16'd40959);

    always @(posedge clk) begin
        if (!rst_n)
            env_tick_cnt <= 16'd0;
        else if (ena)
            env_tick_cnt <= env_tick ? 16'd0 : (env_tick_cnt + 16'd1);
    end

    reg [3:0] env1, env2, env3;

    always @(posedge clk) begin
        if (!rst_n) begin
            env1 <= 4'd0;
            env2 <= 4'd0;
            env3 <= 4'd0;
        end else if (ena) begin
            // Canal 1
            if (!active1) env1 <= 4'd0;
            else if (trig1) env1 <= (timbre == 2'b10) ? 4'd3 : 4'd15;
            else if (env_tick) begin
                if (timbre == 2'b00 && env1 > 4'd2) env1 <= env1 - 4'd1;
                else if (timbre == 2'b10 && env1 < 4'd15) env1 <= env1 + 4'd1;
            end

            // Canal 2
            if (!active2) env2 <= 4'd0;
            else if (trig2) env2 <= (timbre == 2'b10) ? 4'd3 : 4'd15;
            else if (env_tick) begin
                if (timbre == 2'b00 && env2 > 4'd2) env2 <= env2 - 4'd1;
                else if (timbre == 2'b10 && env2 < 4'd15) env2 <= env2 + 4'd1;
            end

            // Canal 3
            if (!active3) env3 <= 4'd0;
            else if (trig3) env3 <= (timbre == 2'b10) ? 4'd3 : 4'd15;
            else if (env_tick) begin
                if (timbre == 2'b00 && env3 > 4'd2) env3 <= env3 - 4'd1;
                else if (timbre == 2'b10 && env3 < 4'd15) env3 <= env3 + 4'd1;
            end
        end
    end

    function [7:0] apply_env;
        input [7:0] w;
        input [3:0] e;
        begin
            case (e[3:2])
                2'b11: apply_env = w;
                2'b10: apply_env = (w >> 1) + (w >> 2);
                2'b01: apply_env = (w >> 1);
                2'b00: apply_env = (e == 4'd0) ? 8'd0 : (w >> 2);
            endcase
        end
    endfunction

    wire [7:0] voice1 = apply_env(raw_wave1, env1);
    wire [7:0] voice2 = apply_env(raw_wave2, env2);
    wire [7:0] voice3 = apply_env(raw_wave3, env3);

    // =========================================================================
    // 6. MEZCLADOR DE 3 VOCES Y MODULADOR SIGMA-DELTA (uo_out[0])
    // =========================================================================
    wire [9:0] mixed_audio = {2'b00, voice1} + {2'b00, voice2} + {2'b00, voice3};
    wire       any_active  = active1 || active2 || active3;
    wire [7:0] dac_in      = any_active ? mixed_audio[9:2] : 8'd128;

    reg [8:0] sd_accum;

    always @(posedge clk) begin
        if (!rst_n)
            sd_accum <= 9'd0;
        else if (ena)
            sd_accum <= {1'b0, sd_accum[7:0]} + {1'b0, dac_in};
    end

    assign uo_out[0] = sd_accum[8];

// =========================================================================
    // 7. DECODIFICADOR DE DISPLAY 7 SEGMENTOS (uo_out[7:1] = {g,f,e,d,c,b,a})
    //    Compatible directo con el display onboard de Tiny Tapeout (Cátodo común)
    // =========================================================================
    reg [6:0] seg7;

    always @(*) begin
        if (!active1) begin
            seg7 = 7'b100_0000; // "-" en reposo (segmento g)
        end else begin
            case (note1)
                4'd0:  seg7 = 7'b011_1001; // C  (Do)
                4'd1:  seg7 = 7'b101_1000; // c  (Do#)
                4'd2:  seg7 = 7'b101_1110; // d  (Re)
                4'd3:  seg7 = 7'b101_1111; // d̅  (Re#)
                4'd4:  seg7 = 7'b111_1001; // E  (Mi)
                4'd5:  seg7 = 7'b111_0001; // F  (Fa)
                4'd6:  seg7 = 7'b111_0101; // F̩  (Fa#)
                4'd7:  seg7 = 7'b011_1101; // G  (Sol)
                4'd8:  seg7 = 7'b110_1111; // g  (Sol#)
                4'd9:  seg7 = 7'b111_0111; // A  (La)
                4'd10: seg7 = 7'b101_1111; // a  (La#)
                4'd11: seg7 = 7'b111_1100; // b  (Si)
                default: seg7 = 7'b000_0000;
            endcase
        end
    end

    assign uo_out[7:1] = seg7;

endmodule
