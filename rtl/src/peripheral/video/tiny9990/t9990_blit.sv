//
// t9990_blit.sv
//
// BSD 3-Clause License
// 
// Copyright (c) 2024, Shinobu Hashimoto
// 
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
// 
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

`default_nettype none

/***************************************************************
 * VDP コマンド
 ***************************************************************/
module T9990_BLIT (
    input wire                  RESET_n,
    input wire                  CLK,
    input wire                  CLK_EN,

    T9990_CMD_MEM_IF.VDP        CMD_MEM,
    T9990_P2_CPU_TO_VDP_IF.VDP  P2_CPU_TO_VDP,
    T9990_P2_VDP_TO_CPU_IF.VDP  P2_VDP_TO_CPU,
    T9990_REGISTER_IF.VDP       REG,
    T9990_STATUS_IF.CMD         STATUS,

    // CONTROL
    input wire                  START          // 開始
);
    wire cond_dst_write_req       = xfer_run && ena_output && !io_req;                          // DST 書き出し要求の条件
    wire cond_dst_write_even_done = xfer_run && ena_output && io_req && io_ack && p1_even;      // DST (P1 偶数)の書き出し完了の条件
    wire cond_dst_write_done      = xfer_run && ena_output && io_req && io_ack && !p1_even;     // DST 書き出し完了の条件

    wire cond_dst_read_req        = xfer_run && ena_dequeue && !io_req;                         // DST 読み出し要求の条件
    wire cond_dst_read_even_done  = xfer_run && ena_dequeue && io_req && io_ack && p1_even;     // DST (P1 偶数)の読み出し完了の条件
    wire cond_dst_read_done       = xfer_run && ena_dequeue && io_req && io_ack && !p1_even;    // DST の読み出し完了の条件

    wire cond_src_read_req        = xfer_run && ena_enqueue && !io_req;                         // SRC 読み出し要求の条件
    wire cond_src_read_even_done  = xfer_run && ena_enqueue && io_req && io_ack &&  p1_even;    // SRC (P1 偶数)の読み出し完了の条件
    wire cond_src_read_done       = xfer_run && ena_enqueue && io_req && io_ack && !p1_even;    // SRC の読み出し完了の条件

    wire cond_src_dequeue_req     = xfer_run && ena_dequeue && !io_req;                         // FIFO 取り出し要求の条件
    wire cond_logop               = xfer_run && ena_logop;                                      // ロジカルオペレーション要求の条件

    /*******************************************
     * P1 モード
     *******************************************/
    reg P1;

    always_ff @(posedge CLK) begin
        if(REG.DSPM[1]) begin
            P1 <= 0;
        end
        else if(REG.DSPM[0]) begin
            P1 <= 0;
        end
        else begin
            P1 <= 1;
        end
    end

    /*******************************************
     * 横幅
     *******************************************/
    reg [1:0] XIMM;

    always_ff @(posedge CLK) begin
        if(REG.DSPM[1]) begin
            XIMM <= REG.XIMM;
        end
        else if(REG.DSPM[0]) begin
            XIMM <= T9990_REG::XIMM_512;
        end
        else begin
            XIMM <= T9990_REG::XIMM_256;
        end
    end

    /*******************************************
     * 繰り返しコマンドフラグ
     *******************************************/
    reg command_is_loop;
    reg command_is_line;
    reg command_is_srch;

    always_ff @(posedge CLK) begin
        command_is_loop <= (REG.OP == T9990_REG::CMD_LINE) || (REG.OP == T9990_REG::CMD_SRCH);

        command_is_line  <= (REG.OP == T9990_REG::CMD_LINE);
        command_is_srch  <= (REG.OP == T9990_REG::CMD_SRCH);
    end

    /*******************************************
     * POINT 動作フラグ
     *******************************************/
    reg is_point;
    always_ff @(posedge CLK) is_point <= (REG.OP == T9990_REG::CMD_POINT) || (REG.OP == T9990_REG::CMD_SRCH);   // POINT と SEARCH はピクセルデータ取得

    /*******************************************
     * SETUP
     *******************************************/
    wire xfer_is_busy = (xfer_setup != 0) || xfer_run;                      // 転送ビジーフラグ
    wire xfer_is_complete = STATUS.CE && !xfer_is_busy;                     // 転送完了フラグ
    wire command_is_complete = xfer_is_complete && !is_continuous;          // コマンド完了
    wire command_is_continue = xfer_is_complete &&  is_continuous;          // コマンド継続

    reg [2:0]                    xfer_setup;                                                        // セットアップフラグ
    wire [$bits(xfer_setup)-1:0] setup_start_value = 1 << ($bits(xfer_setup)-1);                    // 開始時の値
    wire [$bits(xfer_setup)-1:0] setup_shift_value = { 1'b0, xfer_setup[$bits(xfer_setup)-1:1] };   // 次の値

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                            xfer_setup <= 0;                    // RESET
        else if(!CLK_EN)                        ;                                   // タイミング外
        else if(START || command_is_continue)   xfer_setup <= setup_start_value;    // 転送開始/転送再開
        else                                    xfer_setup <= setup_shift_value;    // 転送中/転送終了
    end

    /*******************************************
     * 転送完了後に処理を継続するか？
     *******************************************/
    reg is_continuous;                      // 処理継続フラグ

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                            is_continuous <= 0;                     // RESET
        else if(!CLK_EN)                        ;                                       // タイミング外
        else if(REG.OP == T9990_REG::CMD_STOP)  is_continuous <= 0;                     // STOP
        else if(!command_is_loop)               is_continuous <= 0;                     // ループするコマンドではない
        else if(START)                          is_continuous <= 1;                     // コマンド開始
        else if(command_is_line)                is_continuous <= line_is_continuous;    // LINE 転送完了
        else if(command_is_srch)                is_continuous <= srch_is_continuous;    // SEARCH 転送完了
        else                                    is_continuous <= 0;                     // そのほか
    end

    /*******************************************
     * LINE ループ
     *******************************************/
    // LINE 用ワーク構造体
    struct {
        reg [11:0]   count;                     // ループ回数
        reg [11+1:0] acc;                       // DDA 用
        reg [11+1:0] acc_next;                  // sum の次回の値
        reg [11+1:0] acc_next_mod;              // sum の次回の値(Modulo)
        reg          continuous;
    } line_work;

    // LINE コマンドの継続条件
    wire line_is_continuous = line_work.continuous;

    // 計算
    always_ff @(posedge CLK) begin
        if(CLK_EN && command_is_line) begin
            line_work.acc_next_mod <= line_work.acc_next + REG.MJ;
            line_work.acc_next <= line_work.acc - REG.MI;
        end
    end

    // 繰り返し回数
    always_ff @(posedge CLK) begin
        if(CLK_EN && command_is_line) begin
            if(START)                 line_work.count <= 1'd1;
            else if(xfer_is_complete) line_work.count <= line_work.count - 1'd1;
        end
    end

    // 繰り返しチェック
    always_ff @(posedge CLK) begin
        if(CLK_EN && command_is_line) begin
            line_work.continuous <= START ? 1 : (line_work.count != 1'd1);
        end
    end

    // DDA
    wire line_dda_trig = line_work.acc_next[$bits(line_work.acc_next)-1];
    always_ff @(posedge CLK) begin
        if(CLK_EN && command_is_line) begin
            if(START)                 line_work.acc <= REG.MJ - 1'd1;
            else if(xfer_is_complete) line_work.acc <= line_dda_trig ? line_work.acc_next_mod : line_work.acc_next;
        end
    end

    /*******************************************
     * SEARCH ループ
     *******************************************/
    // SEARCH 用ワーク構造体
    struct {
        reg        clr_neq; // 色データ不一致
        reg        no_edge; // 端検出
        reg [10:0] sx;      // 取得した X 座標
    } srch_work;

    // SEARCH コマンドの継続条件
    wire srch_is_continuous = srch_work.no_edge && !srch_found;

    // 色の比較
    wire srch_found = (REG.NEQ == srch_work.clr_neq);
    always_ff @(posedge CLK) begin
        if(CLK_EN && command_is_srch) begin
            if(START) srch_work.clr_neq <= 1;
            else      srch_work.clr_neq <= ((SRC_DATA ^ {REG.FC,REG.FC}) & BIT_MASK) != 32'd0;
        end
    end

    // 画面端検出
    always_ff @(posedge CLK) begin
        if(CLK_EN && command_is_srch) begin
            if(START) begin
                srch_work.no_edge <= 1;
            end
            else begin
                if(REG.DIX) begin
                    case(XIMM)
                        T9990_REG::XIMM_256:    srch_work.no_edge <= SRC_X[ 7:0] != 0;
                        T9990_REG::XIMM_512:    srch_work.no_edge <= SRC_X[ 8:0] != 0;
                        T9990_REG::XIMM_1024:   srch_work.no_edge <= SRC_X[ 9:0] != 0;
                        default:                srch_work.no_edge <= SRC_X[10:0] != 0;
                    endcase
                end
                else begin
                    case(XIMM)
                        T9990_REG::XIMM_256:    srch_work.no_edge <= SRC_X[ 7:0] !=      8'b1111_1111;
                        T9990_REG::XIMM_512:    srch_work.no_edge <= SRC_X[ 8:0] !=    9'b1_1111_1111;
                        T9990_REG::XIMM_1024:   srch_work.no_edge <= SRC_X[ 9:0] !=  10'b11_1111_1111;
                        default:                srch_work.no_edge <= SRC_X[10:0] != 11'b111_1111_1111;
                    endcase
                end
            end
        end
    end

    // 結果
    always_ff @(posedge CLK) begin
        if(CLK_EN && command_is_srch) begin
            if(START && command_is_srch) begin
                STATUS.BD <= 0;
                srch_work.sx <= REG.SX;
            end
            else if(xfer_is_complete) begin
                if(!srch_is_continuous) begin
                    STATUS.BX <= srch_work.sx;
                    STATUS.BD <= srch_found;
                end
                srch_work.sx <= SRC_X[10:0];
            end
        end
    end

    /*******************************************
     * STATUS.CE bit
     *******************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                    STATUS.CE <= 0; // RESET
        else if(!CLK_EN)                                ;               // タイミング外
        else if(START && REG.OP != T9990_REG::CMD_STOP) STATUS.CE <= 1; // コマンド実行開始
        else if(command_is_complete)                    STATUS.CE <= 0; // コマンド実行完了
    end

    /*******************************************
     * STATUS.CE_intr bit
     *******************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                    STATUS.CE_intr <= 0;    // RESET
        else if(!CLK_EN)                ;                       // タイミング外
        else if(command_is_complete)    STATUS.CE_intr <= 1;    // コマンド実行完了
        else                            STATUS.CE_intr <= 0;    // それ以外
    end

    /*******************************************
     * FIFO クリアフラグ
     *******************************************/
    reg FIFO_CLEAR;     // FIFO クリアフラグ

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                    FIFO_CLEAR <= 1;    // RESET
        else if(!CLK_EN)                ;                   // タイミング外
        else if(!xfer_is_busy)          FIFO_CLEAR <= 1;    // 転送停止中
        else                            FIFO_CLEAR <= 0;    // 転送中
    end

    /*******************************************
     * 座標更新フラグ更新
     *******************************************/
    reg src_nx_over;        // SRC_NX 終端チェック
    reg dst_nx_over;        // DST_NX 終端チェック
    reg src_change_y;       // SRC_Y 移動フラグ
    reg dst_change_y;       // DST_Y 移動フラグ

    wire [4:0] SRC_OUT_COUNT = SRC_COUNT;
    wire [4:0] SRC_POS_COUNT = SRC_COUNT;
    wire [4:0] DST_IN_COUNT = DST_COUNT;
    wire [4:0] DST_POS_COUNT = DST_COUNT;

    always_ff @(posedge CLK) begin
        src_nx_over <= SRC_NX <= SRC_POS_COUNT;    // SRC_NX が読み出し可能数以下なら終端
        dst_nx_over <= DST_NX <= DST_POS_COUNT;    // DST_NX が書き込み可能数以下なら終端
        src_change_y <= SRC_NX <= SRC_POS_COUNT;   // X 終端なら SY 移動
        dst_change_y <= DST_NX <= DST_POS_COUNT;   // X 終端なら DY 移動
    end

    /*******************************************
     * DST_X, DST_Y, DST_NX, DST_NY 更新
     *******************************************/
    reg [1:0]  DST_CLRM;        // DST データビット幅
    reg [18:0] DST_NX;          // DST 横幅(or 転送バイト数)
    reg [11:0] DST_NY;          // DST 縦幅
    reg [18:0] DST_X;           // DST X 座標(or アドレス)
    reg [11:0] DST_Y;           // DST Y 座標
    reg        DST_DIX;         // DST X 移動方向
    reg        dst_is_linear;   // DST リニアアドレス転送フラグ
    reg        dst_is_cpu;      // DST CPU 転送フラグ
    reg        dst_is_xy;       // DST 矩形転送フラグ
    reg        xfer_run;        // 転送中フラグ

    always_ff @(posedge CLK) begin
        if(REG.OP == T9990_REG::CMD_BMLX || REG.OP == T9990_REG::CMD_BMLL) DST_CLRM <= T9990_REG::CLRM_8BPP;    // バイト単位で転送
        else if(REG.DSPM[1])                                               DST_CLRM <= REG.CLRM;                // ピクセル単位で転送
        else                                                               DST_CLRM <= T9990_REG::CLRM_4BPP;    // P1/P2 モード(4BPP)転送
    end

    wire dst_complete = dst_is_linear ? (DST_NX <= DST_POS_COUNT) : (DST_NY == 1'd1);

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            xfer_run <= 0;
        end
        else if(!CLK_EN) begin
        end
        else if(REG.OP == T9990_REG::CMD_STOP) begin
            if(io_free) begin
                xfer_run <= 0;
            end
        end
        else if(xfer_setup[0]) begin
            xfer_run <= 1;

            if(REG.OP == T9990_REG::CMD_BMLL) begin
                // 転送バイト数
                DST_NX <= REG.NA;
                DST_NY <= 1'd1;
            end
            else if(REG.OP == T9990_REG::CMD_POINT || REG.OP == T9990_REG::CMD_PSET || REG.OP == T9990_REG::CMD_ADVN) begin
                // 転送ドット数
                DST_NX <= 1;
                DST_NY <= 1;
            end
            else begin
                // 転送ドット数
                DST_NX <= REG.NX == 0 ? 12'd2048 : REG.NX;
                DST_NY <= REG.NY;
            end

            if(REG.OP == T9990_REG::CMD_BMLX || REG.OP == T9990_REG::CMD_BMLL) begin
                // 転送先アドレス
                DST_X <= REG.DA;
                DST_Y <= 0;
                DST_DIX <= 0;
                dst_is_linear <= 1;
            end
            else begin
                // 転送先座標
                DST_X <= REG.DX;
                DST_Y <= REG.DY;
                DST_DIX <= REG.DIX;
                dst_is_linear <= 0;
            end

            dst_is_cpu <= (REG.OP == T9990_REG::CMD_LMCM) || (REG.OP == T9990_REG::CMD_POINT);
            dst_is_xy  <= (REG.OP == T9990_REG::CMD_LMMC) || (REG.OP == T9990_REG::CMD_LMMV) || (REG.OP == T9990_REG::CMD_LMMM) || (REG.OP == T9990_REG::CMD_LINE) || (REG.OP == T9990_REG::CMD_PSET) || (REG.OP == T9990_REG::CMD_CMMC) || (REG.OP == T9990_REG::CMD_CMMK) || (REG.OP == T9990_REG::CMD_CMMM) || (REG.OP == T9990_REG::CMD_BMXL);
        end
        else if(cond_dst_write_done) begin
            // 残り回数
            if(dst_is_linear) begin
                DST_NX <= DST_NX - DST_POS_COUNT;
            end
            else if(dst_nx_over) begin
                DST_NX <= REG.NX == 0 ? 12'd2048 : REG.NX;
                DST_NY <= DST_NY - 1'd1;
            end
            else begin
                DST_NX <= DST_NX - DST_POS_COUNT;
            end

            // 終わりチェック
            if(dst_complete) begin
                xfer_run <= 0;
            end

            // 座標更新
            if(command_is_line) begin
                if(dst_complete) begin
                    // マイナー移動
                    if(line_dda_trig) begin
                        if(REG.MAJ) DST_X <= REG.DIX ? (DST_X - 1'd1) : (DST_X + 1'd1);
                        else        DST_Y <= REG.DIY ? (DST_Y - 1'd1) : (DST_Y + 1'd1);
                    end

                    // メジャー移動
                    if(!REG.MAJ) DST_X <= REG.DIX ? (DST_X - 1'd1) : (DST_X + 1'd1);
                    else         DST_Y <= REG.DIY ? (DST_Y - 1'd1) : (DST_Y + 1'd1);
                end
            end
            else if(dst_is_linear) begin
                DST_X <= DST_X + DST_POS_COUNT;
            end
            else if(dst_change_y) begin
                DST_X <= REG.DX;
                DST_Y <= REG.DIY ? (DST_Y - 1'd1) : (DST_Y + 1'd1);
            end
            else begin
                DST_X <= DST_DIX ? (DST_X - DST_POS_COUNT) : (DST_X + DST_POS_COUNT);
            end
        end
    end

    /*******************************************
     * SRC_X, SRC_Y, SRC_NX, SRC_NY 更新
     *******************************************/
    reg [1:0]  SRC_CLRM;        // SRC データビット幅
    reg [18:0] SRC_NX;          // SRC 横幅(or 転送バイト数)
    reg [11:0] SRC_NY;          // SRC 縦幅
    reg [18:0] SRC_X;           // SRC X 座標(or アドレス)
    reg [11:0] SRC_Y;           // SRC Y 座標
    reg        SRC_DIX;         // SRC X 移動方向
    reg        src_is_linear;   // SRC リニアアドレス転送フラグ
    reg        src_is_cpu;      // SRC PORT#2フラグ
    reg        src_is_rom;      // SRC ROMフラグ
    reg        src_is_vdp;      // SRC VDP レジスタフラグ
    reg        src_is_char;     // SRC ビットマップデコードフラグ
    reg        src_is_xy;       // SRC 矩形転送フラグ
    reg        src_enable;      // SRC 取得可フラグ

    always_ff @(posedge CLK) begin
        if(REG.OP == T9990_REG::CMD_CMMM || REG.OP == T9990_REG::CMD_BMXL|| REG.OP == T9990_REG::CMD_BMLL) SRC_CLRM <= T9990_REG::CLRM_8BPP;    // バイト単位で転送
        else if(REG.DSPM[1])                                                                               SRC_CLRM <= REG.CLRM;                // ピクセル単位で転送
        else                                                                                               SRC_CLRM <= T9990_REG::CLRM_4BPP;    // P1/P2 モード(4BPP)転送
    end

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            src_enable <= 0;
        end
        else if(!CLK_EN) begin
        end
        else if(REG.OP == T9990_REG::CMD_STOP) begin
            if(io_free) begin
                src_enable <= 0;
            end
        end
        else if(xfer_setup[0]) begin
            src_enable <= 1;

            if(REG.OP == T9990_REG::CMD_BMLL) begin
                // 転送バイト数
                SRC_NX <= REG.NA;
                SRC_NY <= 1'd1;
            end
            else if(REG.OP == T9990_REG::CMD_POINT || REG.OP == T9990_REG::CMD_PSET || REG.OP == T9990_REG::CMD_ADVN) begin
                // 転送ドット数
                SRC_NX <= 1;
                SRC_NY <= 1;
            end
            else begin
                // 転送ドット数
                SRC_NX <= REG.NX == 0 ? 12'd2048 : REG.NX;
                SRC_NY <= REG.NY;
            end

            if(REG.OP == T9990_REG::CMD_CMMM || REG.OP == T9990_REG::CMD_BMXL || REG.OP == T9990_REG::CMD_BMLL) begin
                // 転送元アドレス
                SRC_X <= REG.SA;
                SRC_Y <= 0;
                SRC_DIX <= 0;
                src_is_linear <= 1;
            end
            else begin
                // 転送元座標
                SRC_X <= REG.SX;
                SRC_Y <= REG.SY;
                SRC_DIX <= REG.DIX;
                src_is_linear <= 0;
            end

            src_is_cpu  <= (REG.OP == T9990_REG::CMD_LMMC) || (REG.OP == T9990_REG::CMD_CMMC);
            src_is_rom  <= (REG.OP == T9990_REG::CMD_CMMK);
            src_is_vdp  <= (REG.OP == T9990_REG::CMD_LMMV) || (REG.OP == T9990_REG::CMD_LINE) || (REG.OP == T9990_REG::CMD_PSET) || (REG.OP == T9990_REG::CMD_ADVN);
            src_is_char <= (REG.OP == T9990_REG::CMD_CMMC) || (REG.OP == T9990_REG::CMD_CMMK) || (REG.OP == T9990_REG::CMD_CMMM);
            src_is_xy   <= (REG.OP == T9990_REG::CMD_LMCM) || (REG.OP == T9990_REG::CMD_LMMM) || (REG.OP == T9990_REG::CMD_BMLX) || (REG.OP == T9990_REG::CMD_SRCH) || (REG.OP == T9990_REG::CMD_POINT);
        end
        else if(cond_src_read_done) begin
            // 残り回数
            if(src_is_linear) begin
                SRC_NX <= SRC_NX - SRC_POS_COUNT;
            end
            else if(src_nx_over) begin
                // SRC_NY が 1->0 で転送元入力を禁止
                if(SRC_NY == 1'd1) src_enable <= 0;

                SRC_NX <= REG.NX == 0 ? 12'd2048 : REG.NX;
                SRC_NY <= SRC_NY - 1'd1;
            end
            else begin
                SRC_NX <= SRC_NX - SRC_POS_COUNT;
            end

            // 座標更新
            if(src_is_linear) begin
                // 隣へ移動
                SRC_X <= SRC_X + SRC_POS_COUNT;
            end
            else if(src_change_y) begin
                // 次の行の準備
                SRC_X <= REG.SX;
                SRC_Y <= REG.DIY ? (SRC_Y - 1'd1) : (SRC_Y + 1'd1);
            end
            else begin
                // 隣へ移動
                SRC_X <= SRC_DIX ? (SRC_X - SRC_POS_COUNT) : (SRC_X + SRC_POS_COUNT);
            end
        end
    end

    /*******************************************
     * SRC ADDRESS
     *******************************************/
    reg [18:0] SRC_XY_ADDR;
    T9990_BLIT_ADDR u_src_addr (
        .CLK,
        .CLRM(SRC_CLRM),
        .P1,
        .XIMM,
        .X(SRC_X[10:0]),
        .Y(SRC_Y),
        .ADDR(SRC_XY_ADDR)
    );

    /*******************************************
     * DST ADDRESS
     *******************************************/
    reg [18:0] DST_XY_ADDR;
    T9990_BLIT_ADDR u_dst_addr (
        .CLK,
        .CLRM       (DST_CLRM),
        .P1,
        .XIMM,
        .X          (DST_X[10:0]),
        .Y          (DST_Y),
        .ADDR       (DST_XY_ADDR)
    );

    /*******************************************
     * SRC COUNT
     *******************************************/
    reg [4:0] SRC_COUNT;
    T9990_BLIT_CALC_COUNT u_src_cnt (
        .CLK,
        .CPU_MODE   (src_is_cpu),
        .IS_POINT   (is_point),
        .CLRM       (SRC_CLRM),
        .DIX        (SRC_DIX),
        .OFFSET     (SRC_X[3:0]),
        .REMAIN     (SRC_NX),
        .COUNT      (SRC_COUNT)
    );

    /*******************************************
     * DST COUNT
     *******************************************/
    reg [4:0] DST_COUNT;
    T9990_BLIT_CALC_COUNT u_dst_cnt (
        .CLK,
        .CPU_MODE   (dst_is_cpu),
        .IS_POINT   (is_point),
        .CLRM       (DST_CLRM),
        .DIX        (DST_DIX),
        .OFFSET     (DST_X[3:0]),
        .REMAIN     (DST_NX),
        .COUNT      (DST_COUNT)
    );

    /*******************************************
     * BIT MASK
     *******************************************/
    reg [31:0] BIT_MASK;
    T9990_BLIT_BITMASK u_bitmsk (
        .CLK,
        .WM         (REG.WM),
        .CLRM       (DST_CLRM),
        .DIX        (DST_DIX),
        .OFFSET     (DST_X[3:0]),
        .COUNT      (DST_COUNT),
        .BIT_MASK   (BIT_MASK)
    );

    /*******************************************
     * ENQUEUE
     *******************************************/
    reg         ENQUEUE;
    reg [3:0]   ENQUEUE_SHIFT;
    reg [31:0]  ENQUEUE_DATA;
    reg [4:0]   ENQUEUE_COUNT;

    wire [31:0] cmd_mem_dout_p1_be  = { save_mem_dout[7:0], CMD_MEM.DOUT[7:0], save_mem_dout[15:8], CMD_MEM.DOUT[15:8]};    // 転送元 VRAM 読み出しデータ(P1モード、ビッグエンディアン)
    wire [31:0] cmd_mem_dout_np1_be = { CMD_MEM.DOUT[7:0], CMD_MEM.DOUT[15:8], CMD_MEM.DOUT[23:16], CMD_MEM.DOUT[31:24]};   // 転送元 VRAM 読み出しデータ(ビッグエンディアン)
    wire [31:0] cmd_mem_dout_be  = P1 ? cmd_mem_dout_p1_be : cmd_mem_dout_np1_be;                                           // 転送元 VRAM 読み出しデータ

    reg ena_enqueue;
    always_ff @(posedge CLK) if(CLK_EN) ena_enqueue <= FREE_COUNT >= SRC_OUT_COUNT && src_enable;   // SRC 取得可で FIFO バッファに空きがある場合に ENQUEUE 許可

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            ENQUEUE <= 0;
        end
        else if(!CLK_EN) begin
        end
        else if(REG.OP == T9990_REG::CMD_STOP) begin
            if(io_free) begin
                ENQUEUE <= 0;
            end
        end
        else if(xfer_setup[0]) begin
            ENQUEUE <= 0;
            char_work.decode_data <= 0;
            char_work.decode_count <= 0;
        end
        else begin
            ENQUEUE <= cond_src_read_done;

            if(cond_src_read_done) begin
                //
                if(src_is_char) begin
                    ENQUEUE_COUNT <= 1;
                end
                else begin
                    ENQUEUE_COUNT <= SRC_OUT_COUNT;
                end

                //
                if(src_is_char) begin
                    if(char_work.decode_count == 0) begin
                        case (SRC_CLRM)
                            T9990_REG::CLRM_2BPP:   ENQUEUE_DATA <= {cmd_mem_dout_be[31] ? REG.FC[15:14] :  2'd0, 30'd0};
                            T9990_REG::CLRM_4BPP:   ENQUEUE_DATA <= {cmd_mem_dout_be[31] ? REG.FC[15:12] :  4'd0, 28'd0};
                            T9990_REG::CLRM_8BPP:   ENQUEUE_DATA <= {cmd_mem_dout_be[31] ? REG.FC[15: 8] :  8'd0, 24'd0};
                            T9990_REG::CLRM_16BPP:  ENQUEUE_DATA <=  cmd_mem_dout_be[31] ? REG.FC[15: 0] : 16'd0;
                        endcase
                        ENQUEUE_SHIFT <= 0;
                        char_work.decode_data <= {cmd_mem_dout_be[30:24], cmd_mem_dout_be[31]};
                        char_work.decode_count <= 3'd7;
                    end
                    else begin
                        case (SRC_CLRM)
                            T9990_REG::CLRM_2BPP:   ENQUEUE_DATA <= {char_work.decode_data[7] ? REG.FC[15:14] :  2'd0, 30'd0};
                            T9990_REG::CLRM_4BPP:   ENQUEUE_DATA <= {char_work.decode_data[7] ? REG.FC[15:12] :  4'd0, 28'd0};
                            T9990_REG::CLRM_8BPP:   ENQUEUE_DATA <= {char_work.decode_data[7] ? REG.FC[15: 8] :  8'd0, 24'd0};
                            T9990_REG::CLRM_16BPP:  ENQUEUE_DATA <=  char_work.decode_data[7] ? REG.FC[15: 0] : 16'd0;
                        endcase
                        ENQUEUE_SHIFT <= 0;

                        char_work.decode_data <= {char_work.decode_data[6:0], char_work.decode_data[7]};
                        char_work.decode_count <= char_work.decode_count - 1'd1;
                    end
                end
                else if(src_is_cpu) begin
                    ENQUEUE_DATA <= cmd_mem_dout_be;
                    ENQUEUE_SHIFT <= 0;
                end
                else if(src_is_vdp) begin
                    ENQUEUE_DATA <= {REG.FC,REG.FC};
                    ENQUEUE_SHIFT <= 0;
                end
                else begin
                    if(SRC_DIX) begin
                        // ドットを左右反転して転送元 VRAM データを ENQUEUE_DATA に格納
                        case (SRC_CLRM)
                            T9990_REG::CLRM_2BPP:   ENQUEUE_DATA <= {cmd_mem_dout_be[ 1: 0], cmd_mem_dout_be[ 3: 2], cmd_mem_dout_be[ 5: 4], cmd_mem_dout_be[ 7: 6], cmd_mem_dout_be[ 9: 8], cmd_mem_dout_be[11:10], cmd_mem_dout_be[13:12], cmd_mem_dout_be[15:14], cmd_mem_dout_be[17:16], cmd_mem_dout_be[19:18], cmd_mem_dout_be[21:20], cmd_mem_dout_be[23:22], cmd_mem_dout_be[25:24], cmd_mem_dout_be[27:26], cmd_mem_dout_be[29:28], cmd_mem_dout_be[31:30]};
                            T9990_REG::CLRM_4BPP:   ENQUEUE_DATA <= {cmd_mem_dout_be[ 3: 0], cmd_mem_dout_be[ 7: 4], cmd_mem_dout_be[11: 8], cmd_mem_dout_be[15:12], cmd_mem_dout_be[19:16], cmd_mem_dout_be[23:20], cmd_mem_dout_be[27:24], cmd_mem_dout_be[31:28]};
                            T9990_REG::CLRM_8BPP:   ENQUEUE_DATA <= {cmd_mem_dout_be[ 7: 0], cmd_mem_dout_be[15: 8], cmd_mem_dout_be[23:16], cmd_mem_dout_be[31:24]};
                            T9990_REG::CLRM_16BPP:  ENQUEUE_DATA <= {cmd_mem_dout_be[15: 0], cmd_mem_dout_be[31:16]};
                        endcase
                    end
                    else begin
                        // ドットを反転しないで転送元 VRAM データを ENQUEUE_DATA に格納
                        ENQUEUE_DATA <= cmd_mem_dout_be;
                    end

                    // ビットシフト量を計算
                    case ({SRC_DIX, SRC_CLRM})
                        {1'b0, T9990_REG::CLRM_2BPP}:   ENQUEUE_SHIFT <=   SRC_X[3:0];
                        {1'b0, T9990_REG::CLRM_4BPP}:   ENQUEUE_SHIFT <= { SRC_X[2:0], 1'b0};
                        {1'b0, T9990_REG::CLRM_8BPP}:   ENQUEUE_SHIFT <= { SRC_X[1:0], 2'b00};
                        {1'b0, T9990_REG::CLRM_16BPP}:  ENQUEUE_SHIFT <= { SRC_X[0:0], 3'b000};
                        {1'b1, T9990_REG::CLRM_2BPP}:   ENQUEUE_SHIFT <=  ~SRC_X[3:0];
                        {1'b1, T9990_REG::CLRM_4BPP}:   ENQUEUE_SHIFT <= {~SRC_X[2:0], 1'b0};
                        {1'b1, T9990_REG::CLRM_8BPP}:   ENQUEUE_SHIFT <= {~SRC_X[1:0], 2'b00};
                        {1'b1, T9990_REG::CLRM_16BPP}:  ENQUEUE_SHIFT <= {~SRC_X[0:0], 3'b000};
                    endcase
                end
            end
        end
    end

    /*******************************************
     * DEQUEUE SRC_DATA
     *******************************************/
    reg [31:0]  SRC_DATA;
    reg         DEQUEUE;
    reg [4:0]   DEQUEUE_COUNT;
    reg [3:0]   DEQUEUE_SHIFT;
    wire [31:0] DEQUEUE_DATA;

    reg ena_dequeue;
    always_ff @(posedge CLK) if(CLK_EN) ena_dequeue <= AVAIL_COUNT >= DST_IN_COUNT;     // FIFO に必要な数のデータがたまっているなら DEQUEUE 許可

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            DEQUEUE <= 0;
        end
        else if(!CLK_EN) begin
        end
        else if(REG.OP == T9990_REG::CMD_STOP) begin
            if(io_free) begin
                DEQUEUE <= 0;
            end
        end
        else if(xfer_setup[0]) begin
            DEQUEUE <= 0;
        end
        else begin
            if(DEQUEUE) begin
                // SRC DATA
                if(DST_DIX) begin
                    // 左右反転して SRC_DATA へ格納
                    case (DST_CLRM)
                        T9990_REG::CLRM_2BPP:   SRC_DATA <= {DEQUEUE_DATA[ 1: 0], DEQUEUE_DATA[ 3: 2], DEQUEUE_DATA[ 5: 4], DEQUEUE_DATA[ 7: 6], DEQUEUE_DATA[ 9: 8], DEQUEUE_DATA[11:10], DEQUEUE_DATA[13:12], DEQUEUE_DATA[15:14], DEQUEUE_DATA[17:16], DEQUEUE_DATA[19:18], DEQUEUE_DATA[21:20], DEQUEUE_DATA[23:22], DEQUEUE_DATA[25:24], DEQUEUE_DATA[27:26], DEQUEUE_DATA[29:28], DEQUEUE_DATA[31:30]};
                        T9990_REG::CLRM_4BPP:   SRC_DATA <= {DEQUEUE_DATA[ 3: 0], DEQUEUE_DATA[ 7: 4], DEQUEUE_DATA[11: 8], DEQUEUE_DATA[15:12], DEQUEUE_DATA[19:16], DEQUEUE_DATA[23:20], DEQUEUE_DATA[27:24], DEQUEUE_DATA[31:28]};
                        T9990_REG::CLRM_8BPP:   SRC_DATA <= {DEQUEUE_DATA[ 7: 0], DEQUEUE_DATA[15: 8], DEQUEUE_DATA[23:16], DEQUEUE_DATA[31:24]};
                        T9990_REG::CLRM_16BPP:  SRC_DATA <= {DEQUEUE_DATA[15: 0], DEQUEUE_DATA[31:16]};
                    endcase
                end
                else begin
                    // 左右反転せずに SRC_DATA へ格納
                    SRC_DATA <= DEQUEUE_DATA;
                end
            end

            if(cond_src_dequeue_req) begin
                DEQUEUE_COUNT <= DST_IN_COUNT;

                case ({DST_DIX, DST_CLRM})
                    {1'b0, T9990_REG::CLRM_2BPP}:  DEQUEUE_SHIFT <=   DST_X[3:0];
                    {1'b0, T9990_REG::CLRM_4BPP}:  DEQUEUE_SHIFT <= { DST_X[2:0], 1'b0};
                    {1'b0, T9990_REG::CLRM_8BPP}:  DEQUEUE_SHIFT <= { DST_X[1:0], 2'b0};
                    {1'b0, T9990_REG::CLRM_16BPP}: DEQUEUE_SHIFT <= { DST_X[0:0], 3'b0};
                    {1'b1, T9990_REG::CLRM_2BPP}:  DEQUEUE_SHIFT <=  ~DST_X[3:0];
                    {1'b1, T9990_REG::CLRM_4BPP}:  DEQUEUE_SHIFT <= {~DST_X[2:0], 1'b0};
                    {1'b1, T9990_REG::CLRM_8BPP}:  DEQUEUE_SHIFT <= {~DST_X[1:0], 2'b0};
                    {1'b1, T9990_REG::CLRM_16BPP}: DEQUEUE_SHIFT <= {~DST_X[0:0], 3'b0};
                endcase
            end

            DEQUEUE <= cond_src_dequeue_req;
        end
    end

    /*******************************************
     * FIFO buffer
     *******************************************/
    wire [5:0]  FREE_COUNT;
    wire [5:0]  AVAIL_COUNT;

    T9990_BLIT_FIFO u_fifo (
        .RESET_n,
        .CLK,
        .CLK_EN,
        .CLRM           (SRC_CLRM),
        .FREE_COUNT,
        .AVAIL_COUNT,
        .CLEAR          (FIFO_CLEAR),
        .ENQUEUE,
        .ENQUEUE_COUNT,
//      .ENQUEUE_SHIFT,
        .ENQUEUE_DATA,
        .DEQUEUE,
        .DEQUEUE_COUNT,
        .DEQUEUE_SHIFT,
        .DEQUEUE_DATA
    );

    /*******************************************
     * WRT_DATA 生成許可制御
     *******************************************/
    reg ena_logop;

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                ena_logop <= 0;                     // RESET
        else if(!CLK_EN)            ;                                   // タイミング外
        else                        ena_logop <= cond_dst_read_done;    // DST 読み出し完了後に LOGOP 許可
    end

    /*******************************************
     * WRT_DATA 生成(LOGOP)
     *******************************************/
    reg [31:0]  WRT_DATA;
    reg [31:0]  DST_DATA;

    wire [31:0] src_data_le = {SRC_DATA[7:0], SRC_DATA[15:8], SRC_DATA[23:16], SRC_DATA[31:24]};        // ロジカルオペレーション SRC データ(リトルエンディアン)
    wire [31:0] bit_mask_le = {BIT_MASK[7:0], BIT_MASK[15:8], BIT_MASK[23:16], BIT_MASK[31:24]};        // ビットマスク(リトルエンディアン)
    wire [31:0] masked_src_data_le = src_data_le & bit_mask_le;                                         // ビットマスク後の SRC データ(リトルエンディアン)

    wire [31:0] LOGOP = ((REG.LO[2'b00] ? (~src_data_le & ~DST_DATA) : 32'b0) |
                         (REG.LO[2'b01] ? (~src_data_le &  DST_DATA) : 32'b0) |
                         (REG.LO[2'b10] ? ( src_data_le & ~DST_DATA) : 32'b0) |
                         (REG.LO[2'b11] ? ( src_data_le &  DST_DATA) : 32'b0));

    always_ff @(posedge CLK) begin
        if(!CLK_EN) begin
        end
        else if(cond_logop) begin
            if(REG.TP) begin
                // 1ドット毎に 0 と比較してライトデータを作成
                if(DST_CLRM == T9990_REG::CLRM_2BPP) begin
                    WRT_DATA <= {
                        (masked_src_data_le[31:30] != 0) ? LOGOP[31:30] : DST_DATA[31:30],
                        (masked_src_data_le[29:28] != 0) ? LOGOP[29:28] : DST_DATA[29:28],
                        (masked_src_data_le[27:26] != 0) ? LOGOP[27:26] : DST_DATA[27:26],
                        (masked_src_data_le[25:24] != 0) ? LOGOP[25:24] : DST_DATA[25:24],
                        (masked_src_data_le[23:22] != 0) ? LOGOP[23:22] : DST_DATA[23:22],
                        (masked_src_data_le[21:20] != 0) ? LOGOP[21:20] : DST_DATA[21:20],
                        (masked_src_data_le[19:18] != 0) ? LOGOP[19:18] : DST_DATA[19:18],
                        (masked_src_data_le[17:16] != 0) ? LOGOP[17:16] : DST_DATA[17:16],
                        (masked_src_data_le[15:14] != 0) ? LOGOP[15:14] : DST_DATA[15:14],
                        (masked_src_data_le[13:12] != 0) ? LOGOP[13:12] : DST_DATA[13:12],
                        (masked_src_data_le[11:10] != 0) ? LOGOP[11:10] : DST_DATA[11:10],
                        (masked_src_data_le[ 9: 8] != 0) ? LOGOP[ 9: 8] : DST_DATA[ 9: 8],
                        (masked_src_data_le[ 7: 6] != 0) ? LOGOP[ 7: 6] : DST_DATA[ 7: 6],
                        (masked_src_data_le[ 5: 4] != 0) ? LOGOP[ 5: 4] : DST_DATA[ 5: 4],
                        (masked_src_data_le[ 3: 2] != 0) ? LOGOP[ 3: 2] : DST_DATA[ 3: 2],
                        (masked_src_data_le[ 1: 0] != 0) ? LOGOP[ 1: 0] : DST_DATA[ 1: 0]
                    };
                end
                else if(DST_CLRM == T9990_REG::CLRM_4BPP) begin
                    WRT_DATA <= {
                        (masked_src_data_le[31:28] != 0) ? LOGOP[31:28] : DST_DATA[31:28],
                        (masked_src_data_le[27:24] != 0) ? LOGOP[27:24] : DST_DATA[27:24],
                        (masked_src_data_le[23:20] != 0) ? LOGOP[23:20] : DST_DATA[23:20],
                        (masked_src_data_le[19:16] != 0) ? LOGOP[19:16] : DST_DATA[19:16],
                        (masked_src_data_le[15:12] != 0) ? LOGOP[15:12] : DST_DATA[15:12],
                        (masked_src_data_le[11: 8] != 0) ? LOGOP[11: 8] : DST_DATA[11: 8],
                        (masked_src_data_le[ 7: 4] != 0) ? LOGOP[ 7: 4] : DST_DATA[ 7: 4],
                        (masked_src_data_le[ 3: 0] != 0) ? LOGOP[ 3: 0] : DST_DATA[ 3: 0]
                    };
                end
                else if(DST_CLRM == T9990_REG::CLRM_8BPP) begin
                    WRT_DATA <= {
                        (masked_src_data_le[31:24] != 0) ? LOGOP[31:24] : DST_DATA[31:24],
                        (masked_src_data_le[23:16] != 0) ? LOGOP[23:16] : DST_DATA[23:16],
                        (masked_src_data_le[15: 8] != 0) ? LOGOP[15: 8] : DST_DATA[15: 8],
                        (masked_src_data_le[ 7: 0] != 0) ? LOGOP[ 7: 0] : DST_DATA[ 7: 0]
                    };
                end
                else begin
                    WRT_DATA <= {
                        (masked_src_data_le[31:16] != 0) ? LOGOP[31:16] : DST_DATA[31:16],
                        (masked_src_data_le[15: 0] != 0) ? LOGOP[15: 0] : DST_DATA[15: 0]
                    };
                end
            end
            else begin
                // ライトデータを作成
                WRT_DATA <= (LOGOP & bit_mask_le) | (DST_DATA & ~bit_mask_le);
            end
        end
    end

    /*******************************************
     * DST 出力許可制御
     *******************************************/
    reg ena_output;

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                 ena_output <= 0;   // RESET
        else if(!CLK_EN)             ;                  // タイミング外
        else if(cond_logop)          ena_output <= 1;   // LOGOP 実行したら出力許可
        else if(cond_dst_write_done) ena_output <= 0;   // DST 書き込み完了したら出力禁止
    end

    /*******************************************
     * DST データ取得が必要か？
     *******************************************/
    reg req_dst_vram;

    always_ff @(posedge CLK) begin
        if(!(dst_is_linear || dst_is_xy))               req_dst_vram <= 0;  // VRAM に出力しない場合は必要なし
        else if(BIT_MASK != 32'hFFFF_FFFF)              req_dst_vram <= 1;  // ビットマスクに抜けがある場合は必要
        else if(REG.TP)                                 req_dst_vram <= 1;  // 透明色を使う場合は必要
        else if(REG.LO != 4'b1100 && REG.LO != 4'b0011) req_dst_vram <= 1;  // ビット演算を行う場合は必要
        else                                            req_dst_vram <= 0;  // それ以外は必要なし
    end

    /*******************************************
     * データの入出力
     *******************************************/
    // CHAR 用ワーク構造体
    struct {
        reg [5:0] decode_count;
        reg [31:0] decode_data;
    } char_work;

    reg  io_req;                                        // I/O 要求中フラグ
    wire io_ack = CMD_MEM.BUSY || P2_VDP_TO_CPU.ACK;    // I/O 要求受付フラグ
    reg  p1_even;                                       // P1 偶数/奇数
    wire io_free = !io_req && !io_ack &&                // I/O 空きフラグ
                   !cond_dst_write_req &&
                   !cond_dst_write_even_done &&
                   !cond_dst_read_req &&
                   !cond_dst_read_even_done &&
                   !cond_src_read_req &&
                   !cond_src_read_even_done;

    reg [15:0] save_mem_dout;                           // P1 モード VRAM0 データ一時保存用

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            io_req <= 0;
            CMD_MEM.OE_n <= 1;
            CMD_MEM.WE_n <= 1;
        end
        else if(!CLK_EN) begin
        end

        //
        // OUT WRT_DATA
        //
        else if(cond_dst_write_req) begin
            io_req <= 1;

            // VRAM リニア(P1)
            if(P1 && dst_is_linear) begin
                p1_even <= 1;
                CMD_MEM.WE_n <= 0;
                CMD_MEM.ADDR <= { 1'b0, DST_X[18:2], 1'b0};         // 偶数アドレス(VRAM0)書き込み
                CMD_MEM.DIN <= {WRT_DATA[23:16], WRT_DATA[7:0], WRT_DATA[23:16], WRT_DATA[7:0]};
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_16;
            end

            // VRAM リニア
            else if(dst_is_linear) begin
                p1_even <= 0;
                CMD_MEM.WE_n <= 0;
                CMD_MEM.ADDR <= {DST_X[18:2], 2'b00};
                CMD_MEM.DIN <= WRT_DATA;
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_32;
            end

            // VRAM 矩形
            else if(dst_is_xy) begin
                p1_even <= 0;
                CMD_MEM.WE_n <= 0;
                CMD_MEM.ADDR <= DST_XY_ADDR;
                CMD_MEM.DIN <= WRT_DATA;
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_32;
            end

            // P#2
            else if(dst_is_cpu) begin
                p1_even <= 0;
                P2_VDP_TO_CPU.REQ <= 1;
                STATUS.TR <= 1;
                if(DST_CLRM == T9990_REG::CLRM_16BPP) begin
                    P2_VDP_TO_CPU.DATA <= WRT_DATA[23:16];
                end
                else begin
                    P2_VDP_TO_CPU.DATA <= WRT_DATA[31:24];
                end
            end
        end
        else if(cond_dst_write_even_done) begin
            p1_even <= 0;
            CMD_MEM.WE_n <= 0;
            CMD_MEM.ADDR <= { 1'b1, DST_X[18:2], 1'b0};         // 偶数アドレス(VRAM0)書き込み
            CMD_MEM.DIN <= {WRT_DATA[31:24], WRT_DATA[15:8], WRT_DATA[31:24], WRT_DATA[15:8]};
            CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_16;
        end
        else if(cond_dst_write_done) begin
            io_req <= 0;
        end

        //
        // INPUT DST_DATA
        //
        else if(cond_dst_read_req) begin
            io_req <= 1;

            // DST 側の VRAM データが必要なら読み出し
            if(!req_dst_vram) begin
                p1_even <= 0;
            end

            // VRAM リニア(P1)
            else if(P1 && dst_is_linear) begin
                p1_even <= 1;
                CMD_MEM.OE_n <= 0;
                CMD_MEM.ADDR <= {1'b0, DST_X[18:2], 1'b0};
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_16;
            end

            // VRAM リニア
            else if(dst_is_linear) begin
                p1_even <= 0;
                CMD_MEM.OE_n <= 0;
                CMD_MEM.ADDR <= {DST_X[18:2], 2'b00};
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_32;
            end

            // VRAM 矩形
            else begin
                p1_even <= 0;
                CMD_MEM.OE_n <= 0;
                CMD_MEM.ADDR <= DST_XY_ADDR;
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_32;
            end
        end
        else if(cond_dst_read_even_done) begin
            save_mem_dout <= CMD_MEM.DOUT[15:0];
            p1_even <= 0;
            CMD_MEM.OE_n <= 0;
            CMD_MEM.ADDR <= {1'b1, DST_X[18:2], 1'b0};
            CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_16;
        end
        else if(cond_dst_read_done) begin
            io_req <= 0;
            DST_DATA <= CMD_MEM.DOUT;
        end

        //
        // INPUT SRC
        //
        else if(cond_src_read_req) begin
            io_req <= 1;

            // CHAR
            if(src_is_char && char_work.decode_count != 0) begin
                // データを読み込まずにデコードの続きをする
                p1_even <= 0;
            end

            // VRAM リニア(P1)
            else if(P1 && src_is_linear) begin
                p1_even <= 1;
                CMD_MEM.OE_n <= 0;
                CMD_MEM.ADDR <= {1'b0, SRC_X[18:2], 1'b0};          // 偶数アドレス(VRAM0)読み出し
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_16;
            end

            // VRAM リニア
            else if(src_is_linear) begin
                p1_even <= 0;
                CMD_MEM.OE_n <= 0;
                CMD_MEM.ADDR <= {SRC_X[18:2], 2'b00};
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_32;
            end

            // VRAM 矩形
            else if(src_is_xy) begin
                p1_even <= 0;
                CMD_MEM.OE_n <= 0;
                CMD_MEM.ADDR <= SRC_XY_ADDR;
                CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_32;
            end

            // P#2
            else if(src_is_cpu) begin
                p1_even <= 0;
                P2_CPU_TO_VDP.REQ <= 1;
                STATUS.TR <= 1;
            end

            // ROM
            else if(src_is_rom) begin
                p1_even <= 0;
                // ToDo: read ROM
            end

            // VDP
            else begin
                p1_even <= 0;
                // データの読み込みなし
            end
        end
        else if(cond_src_read_even_done) begin
            save_mem_dout <= CMD_MEM.DOUT[15:0];
            p1_even <= 0;
            CMD_MEM.OE_n <= 0;
            CMD_MEM.ADDR <= {1'b1, SRC_X[18:2], 1'b0};          // 偶数アドレス(VRAM0)読み出し
            CMD_MEM.DIN_SIZE <= RAM::DIN_SIZE_16;
        end
        else if(cond_src_read_done) begin
            io_req <= 0;
        end
    end
endmodule

/***************************************************************
 * 処理するドット数を計算
 ***************************************************************/
module T9990_BLIT_CALC_COUNT (
    input wire          CLK,
    input wire          CPU_MODE,
    input wire          IS_POINT,
    input wire [1:0]    CLRM,
    input wire          DIX,
    input wire [3:0]    OFFSET,
    input wire [18:0]   REMAIN,
    output reg [4:0]    COUNT
);
    // 1クロック目
    reg [4:0] remain;
    always_ff @(posedge CLK) begin
        if(IS_POINT) remain <= 5'd1;
        else         remain <= (REMAIN[18:4] != 0) ? 5'd16 : REMAIN[3:0];
    end

    reg [4:0] count;
    always_ff @(posedge CLK) begin
        if(CPU_MODE) begin
            case (CLRM)
                T9990_REG::CLRM_2BPP:   count <= 4;
                T9990_REG::CLRM_4BPP:   count <= 2;
                T9990_REG::CLRM_8BPP:   count <= 1;
                T9990_REG::CLRM_16BPP:  count <= 1;
            endcase
        end
        else case (CLRM)
            T9990_REG::CLRM_2BPP:   count <= DIX ? (OFFSET[3:0] + 5'd1) : (5'd16 - OFFSET[3:0]);
            T9990_REG::CLRM_4BPP:   count <= DIX ? (OFFSET[2:0] + 5'd1) : (5'd8  - OFFSET[2:0]);
            T9990_REG::CLRM_8BPP:   count <= DIX ? (OFFSET[1:0] + 5'd1) : (5'd4  - OFFSET[1:0]);
            T9990_REG::CLRM_16BPP:  count <= DIX ? (OFFSET[0:0] + 5'd1) : (5'd2  - OFFSET[0:0]);
        endcase
    end

    // 2クロック目
    always_ff @(posedge CLK) begin
        COUNT <= count > remain ? remain : count;
    end
endmodule

`default_nettype wire
