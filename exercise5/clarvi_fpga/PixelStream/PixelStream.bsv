/*-
 * Copyright (c) 2012-2014 Simon W. Moore
 * All rights reserved.
 *
 * This software was developed by SRI International and the University of
 * Cambridge Computer Laboratory under DARPA/AFRL contract FA8750-10-C-0237
 * ("CTSRD"), as part of the DARPA CRASH research programme.
 *
 * @BERI_LICENSE_HEADER_START@
 *
 * Licensed to BERI Open Systems C.I.C. (BERI) under one or more contributor
 * license agreements.  See the NOTICE file distributed with this work for
 * additional information regarding copyright ownership.  BERI licenses this
 * file to you under the BERI Hardware-Software License, Version 1.0 (the
 * "License"); you may not use this file except in compliance with the
 * License.  You may obtain a copy of the License at:
 *
 *   http://www.beri-open-systems.org/legal/license-1-0.txt
 *
 * Unless required by applicable law or agreed to in writing, Work distributed
 * under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * @BERI_LICENSE_HEADER_END@
 *
 ******************************************************************************
 PixelStream
 ===========
 Simon Moore, Feb 2013
 Simon Moore, Sep 2014

 This DMA's pixels out of memory (e.g. DDR2 memory with a 256 bit wide
 interface) and streams them to a video output device (e.g. HDMI or LCD).

 Pixels are 32-bit with 8-bit channels: (alpha,r,g,b)
 Pixels are in big endian format with b=LSB (if big endian)

 Currently the peripheral has two clocks:
  1. the main clock which should be taken from the DDR2 device to time
     burst transfers (typically 200MHz)
  2. a video pixel clock used for HDMI output which must run at a lower
     clock rate to the main clock

 There is an AvalonMM slave interface with the following configuration
 registers (byte addresses):

 0x00  x-resolution (32-bit access, 12-bit unsigned number with other bits zero)
 0x04  Hsync pulse width (in pixel clocks)
 0x08  Hsync back porch  (in pixel clocks)
 0x0c  Hsync front porch (in pixel clocks)
 0x10  y-resolution (32-bit access, 12-bit unsigned number with other bits zero)
 0x14  Vsync pulse width (in pixel clocks)
 0x18  Vsync back porch  (in pixel clocks)
 0x1c  Vsync front porch (in pixel clocks)
 0x20  base byte-address of pixels - lower 32-bits
 0x24  reserved for upper 32-bit word of 64-bit base address (currently unused)

 if x-resolutions or y-resolution are zero then the device is disabled

 Initially PixelStream is, from reset, configured to be 800 x 600 resolution
 for a 38.2MHz pixel clock giving 60Hz refresh rate.  The base address is zero.

 These parameters are:
   800, 80, 32, 112
   600, 3, 1, 18

 ******************************************************************************

 TODO
 ====

 * put avalon slave interface for parameters into a separate clock domain?
 * reset hdmi when video parameters are changed?
 * cause burst reader to restart when the resolution changes?  necessary?
 * to handle higher resolutions, it would be good to transfer two pixels per
   clock cycle from BurstRead to the HDMI_Timing to improve bandwidth between

 ******************************************************************************/


package PixelStream;

import Clocks::*;
import FIFO::*;
import FIFOF::*;
import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;
import AvalonStreaming::*;
import Avalon2ClientServer::*;
import AvalonBurstMasterWordAddressed::*;

typedef 31 DDR2_Addr_Width;
typedef 1 DDR2_Burst_Length;
typedef UInt#(64) BaseAddrT;
typedef 1 BusWidthWords; //TDiv#(SizeOf#(AvalonBurstWordT),32)

typedef UInt#(8) ColourChanT;

// little endian pixel format
typedef struct {
  UInt#(5) r;     // blue (LSB)
  UInt#(6) g;     // green
  UInt#(5) b;     // red
//  Bool alpha; // alpha blend (unused) (MSB)
} RGBT deriving (Bits,Eq);

// AvalonStream type for 24-bit pixels with start-of-frame marked
typedef struct {
  ColourChanT b;    // red
  ColourChanT g;    // green
  ColourChanT r;    // blue
  Bool        sof;  // start of frame
} Pixel24bT deriving (Bits,Eq);

typedef Int#(16) VideoUnitT; // video units     TODO: use Bit#(12) ????
typedef Int#(TMul#(SizeOf#(VideoUnitT),2)) ResDimT; // resolution dimension

//typedef enum {Xres=0, Hsync_pulse_width=1, Hsync_back_porch=2, Hsync_front_porch=3,
//        Yres=4, Vsync_pulse_width=5, Vsync_back_porch=6, Vsync_front_porch=7}
//        VideoParamName deriving (Bits, Eq);

typedef struct {
  VideoUnitT vsync_front_porch; // parameter 7
  VideoUnitT vsync_back_porch;  // parameter 6
  VideoUnitT vsync_pulse_width; // parameter 5
  VideoUnitT yres;              // parameter 4

  VideoUnitT hsync_front_porch; // parameter 3
  VideoUnitT hsync_back_porch;  // parameter 2
  VideoUnitT hsync_pulse_width; // parameter 1
  VideoUnitT xres;              // parameter 0
} VideoParamT deriving (Bits, Eq);


/*****************************************************************************
 * Video Parameters from Avalon Slave Memory Mapped interface
 *****************************************************************************/

interface VideoParametersIfc;
  interface AvalonSlaveIfc#(4) avalon_slave;
  (* always_enabled, always_ready *)
  method VideoParamT readParam();
  (* always_enabled, always_ready *)
  method BaseAddrT   readBase();
endinterface


// memory mapped interface to video parameters
module mkVideoParameters(VideoParametersIfc);
  AvalonSlave2ClientIfc#(4)    mmap_slave <- mkAvalonSlave2Client;
  Reg#(Bit#(SizeOf#(BaseAddrT)))     base <- mkReg(64'h0800_0000);
  Vector#(8, Reg#(VideoUnitT))          p;
  p[0] <- mkReg(480); // xres
  p[1] <- mkReg(41); // hsync_pulse_width
  p[2] <- mkReg(88); // hsync_back_porch
  p[3] <- mkReg(8); // hsync_front_porch
  p[4] <- mkReg(272); // yres
  p[5] <- mkReg(10); // vsync_pulse_width
  p[6] <- mkReg(12); // vsync_back_porch
  p[7] <- mkReg(3); // vsync_front_porch

  let vp = VideoParamT{
    vsync_front_porch: p[7],
    vsync_back_porch:  p[6],
    vsync_pulse_width: p[5],
    yres:              p[4],

    hsync_front_porch: p[3],
    hsync_back_porch:  p[2],
    hsync_pulse_width: p[1],
    xres:              p[0]
  };

  rule handle_avalon_accesses;
    let req <- mmap_slave.client.request.get();
    ReturnedDataT rtn = tagged Invalid;
    Bit#(1) addr_upper = pack(req.addr)[3];
    case(tuple2(addr_upper, req.rw))
      tuple2(0, MemWrite): begin
        p[req.addr] <= unpack(truncate(pack(req.data)));
        $display("%05t: VideoParameter[%d]=%d", $time, req.addr, req.data);
      end
      tuple2(0, MemRead):  begin
        AvalonWordT d = unpack(zeroExtend(pack(p[req.addr])));
        rtn = tagged Valid d;
      end
      tuple2(1, MemWrite): case(req.addr)
        8: base[31:0]  <= pack(req.data);
        9: base[63:32] <= pack(req.data);
      endcase
      tuple2(1, MemRead):  case(req.addr)
        8: rtn = tagged Valid unpack(base[31:0]);
        9: rtn = tagged Valid unpack(base[63:32]);
        default: rtn = tagged Valid unpack(~0);
      endcase
    endcase
    mmap_slave.client.response.put(rtn);
  endrule

  interface avalon_slave = mmap_slave.avs;
  method VideoParamT readParam = vp;
  method BaseAddrT  readBase() = unpack(base);
endmodule


/*****************************************************************************
 * Avalon Master Burst Reader to read in pixels from fast (e.g. DDR2) memory
 *****************************************************************************/

interface BurstReadIfc;
  interface AvalonPipelinedMasterIfc#(DDR2_Addr_Width) avalon_master_phy;
  interface Get#(Pixel24bT) pixel_stream;
  method Action params(BaseAddrT base, ResDimT number_pixels);
endinterface

typedef Int#(SizeOf#(ResDimT)) BurstReadAddrT;

(* synthesize *)
module mkBurstRead(BurstReadIfc);
  Server2AvalonPipelinedMasterIfc#(DDR2_Addr_Width)
    avalon_master <- mkServer2AvalonPipelinedMaster;
  // address storage for 32-byte (256-bit) addressing
  Reg#(UInt#(DDR2_Addr_Width))  base_addr <- mkReg(0);
  Reg#(UInt#(DDR2_Addr_Width))       addr <- mkReg(0);
  Reg#(ResDimT)                num_pixels <- mkReg(0);
  Reg#(BurstReadAddrT)           pixelctr <- mkReg(0);
  Reg#(BurstReadAddrT)            addrctr <- mkReg(0);
  Reg#(Bool)                   startFrame <- mkReg(False);
  FIFOF#(Pixel24bT)                pixbuf <- mkSizedFIFOF(32);
  Vector#(1,Reg#(RGBT))              pix7 <- replicateM(mkReg(unpack(0)));
  Reg#(UInt#(1))              demux_state <- mkReg(0);

  let maxBurst = 1; //fromInteger(valueof(DDR2_Max_Burst_Length));

  rule start_frame_off((pixelctr<=0) && (addrctr<=0) && (num_pixels>0) && !pixbuf.notEmpty);
    pixelctr   <= unpack(pack(num_pixels));
    addr       <= base_addr;
    // 8 pixels per memory read
    addrctr    <= unpack(pack(num_pixels>>1) + (((num_pixels & 1)!=0) ? 1 : 0));
    //addrctr	<= unpack(pack(num_pixels));
    startFrame <= True;
    $display("%05t: starting frame base_addr=0x%08x, addrctr=0x%08x, pixelctr=0x%08x", $time, base_addr, unpack(pack(num_pixels>>1) + (((num_pixels & 1)!=0) ? 1 : 0)), unpack(pack(num_pixels)));
    //pixbuf.clear();
  endrule

  rule start_bursts((addrctr>0) && avalon_master.canPut(1));
    BurstLength bl = (addrctr>maxBurst) ? maxBurst : unpack(truncate(pack(addrctr)));
    $display("%05t: PixelStream initiating burst length %1d  address=0x%08x", $time, bl, addr);
    avalon_master.server.request.put(MemAccessPacketT{
      rw: tagged MemRead bl,
      addr: addr,
      data: 0
    });
    // Notes:
    // - the following don't need to be a function of "bl" to be correct
    //   since they will be reset once addrctr<=0
    // - the address (addr) and counter are indexing 256-bit = 32-byte units
    addr    <= addr+maxBurst;
    addrctr <= addrctr-maxBurst;
  endrule

  rule pixel_demux_s0((demux_state==0) && (pixelctr>0));
    // read data from burst buffers in avalon burst reader
    AvalonBurstWordT w <- avalon_master.server.response.get();
    $display("Memory returned word 0x%08x", w);
    Vector#(TDiv#(SizeOf#(AvalonBurstWordT),16),Bit#(16)) b8 = unpack(pack(w));
//    RGBT pixcol = unpack(truncate(b8[0]));
    Bit#(16) pix = pack(b8[0]);
    ColourChanT r = unpack({pix[15:11],3'b0});
    ColourChanT g = unpack({pix[10:5],2'b0});
    ColourChanT b = unpack({pix[4:0],3'b0});
    pixbuf.enq(Pixel24bT{r: r, g: g, b: b, sof: startFrame});
//    $display("Pixel %d buffer enqueued  first 0x%08x", pixelctr, Pixel24bT{r: r, g: g, b: b, sof: startFrame});
    $display("Pixel %d buffer enqueued  first 0x%08x", pixelctr, Pixel24bT{r: r, g: g, b: b, sof: startFrame});
    startFrame <= False;
    let next_pixelctr = pixelctr-1;
    pixelctr <= next_pixelctr;
//    for(Integer j=0; j < TDiv#(SizeOf#(AvalonBurstWordT),16); j=j+1) begin
    for(Integer j=0; j<1; j=j+1) begin
      pix7[j] <= unpack(truncate(b8[j+1]));
    end
    demux_state <= (next_pixelctr == 0) ? 0 : 1; // 1;
  endrule

  rule pixel_demux((demux_state!=0) && (pixelctr>0));
//    RGBT pixcol = unpack(truncate(b8[demux_state]));
    Bit#(16) pix = pack(pix7[demux_state-1]);
//    Bit#(16) pix = pack(b8[demux_state-1]);
    ColourChanT r = unpack({pix[15:11],3'b0});
    ColourChanT g = unpack({pix[10:5],2'b0});
    ColourChanT b = unpack({pix[4:0],3'b0});
    pixbuf.enq(Pixel24bT{r: r, g: g, b: b, sof: False});
//    pixbuf.enq(Pixel24bT{r: pixcol.r, g: pixcol.g, b: pixcol.b, sof: False});
    $display("Pixel %d buffer enqueued %dth 0x%08x", pixelctr, demux_state, Pixel24bT{r: r, g: g, b: b, sof: False});
    let next_pixelctr = pixelctr-1;
    pixelctr <= next_pixelctr;
    demux_state <= (next_pixelctr == 0) ? 0 : 0; //demux_state+1;
  endrule

  interface avalon_master_phy = avalon_master.avm;
  interface Get pixel_stream = toGet(pixbuf);

  method Action params(BaseAddrT base, ResDimT number_pixels);
    base_addr  <= truncate(base/4);
    num_pixels <= number_pixels;
  endmethod
endmodule


/******************************************************************************
 * HDMI Timing Driver
 ******************************************************************************/

// 12-bit HDMI channel colour
typedef UInt#(8) HDMIColourChanT;

// convert 8-bit channel colour into 12-bit HDMI colour
function HDMIColourChanT hdmiCol(ColourChanT col8);
  HDMIColourChanT c12 = col8;
  return c12;  // correct if 24-bit colour mode selected on HDMI chip
endfunction

(* always_ready, always_enabled *)
interface HDMIphysical;
  // LCD physical interface
  method HDMIColourChanT hdmi_r; // red
  method HDMIColourChanT hdmi_g; // green
  method HDMIColourChanT hdmi_b; // blue
  method Bool hdmi_hsd;          // hsync
  method Bool hdmi_vsd;          // vsync
  method Bool hdmi_de;           // data enable
  method Clock hdmi_dclk;	 // video clock
endinterface

interface HDMI_Timing_Ifc;
  interface Put#(Pixel24bT) pixel_stream;
  interface HDMIphysical phy;
  (* always_ready, always_enabled *)
  method Action videoparams(VideoParamT p);
endinterface


module mkHDMI_Timing(HDMI_Timing_Ifc);

  Wire#(VideoParamT) vp <- mkBypassWire;
  Clock vidclk <- exposeCurrentClock;

  let        hsync_time = vp.hsync_pulse_width + vp.hsync_back_porch;
  let        vsync_time = vp.vsync_pulse_width + vp.vsync_back_porch;
  let          no_pixel = Pixel24bT{r:0,g:0,b:0,sof:False};
  let         red_pixel = Pixel24bT{r:~0,g:0,b:0,sof:True};

  FIFOF#(Pixel24bT) pixel_buf <- mkSizedFIFOF(64);
//mkGFIFOF(False,True); // unguarded deq
//mkSizedFIFOF(64); - TODO need more buffering and unguarded deq????
  Reg#(Pixel24bT)   pixel_out <- mkRegU;
  Reg#(Bool)              vsd <- mkRegU;
  Reg#(Bool)              hsd <- mkRegU;
  Reg#(Bool)               de <- mkRegU;               // data enable for HDMI
  Reg#(Bool)        output_on <- mkReg(False);
  Reg#(VideoUnitT)          x <- mkReg(0);
  Reg#(VideoUnitT)          y <- mkReg(0);

  rule init(!output_on);
//    x <= -hsync_time;
//    y <= -vsync_time;
    if(pixel_buf.first.sof) begin
      output_on <= !pixel_buf.notFull; // start when the buffer is full
    end else begin
      pixel_buf.deq; // remove pixels until the start of frame is reached
    end
  endrule

  rule scan(output_on);
    // Note the above explicit condition that we have pixels to render
    if(x < (vp.xres+vp.hsync_front_porch-1)) begin
      x <= x+1;
    end else begin
      x <= -hsync_time;
      if(y < (vp.yres+vp.vsync_front_porch-1)) begin
        y <= y+1;
      end else begin
        // end of frame reached
        y <= -vsync_time;
        // go back to init if there are still pixels to be removed from the pixel buffer
        // output_on <= pixel_buf.first.sof;
      end
    end

    Bool hsync_pulse = (x < (-vp.hsync_back_porch));
    Bool vsync_pulse = (y < (-vp.vsync_back_porch));
    hsd <= !hsync_pulse;
    vsd <= !vsync_pulse;

    // determine drawing region
    Bool drawing = (y>=0) && (y<vp.yres) && (x>=0) && (x<vp.xres);
    Bool first_pixel = (x==0) && (y==0);

    // determine pixel colour
    let pixel_col = no_pixel;
    if(drawing) begin // in drawing region
      // check that the pixel stream is synchronised with the LCD timing,
      // otherwise output red
      if(pixel_buf.notEmpty && (pixel_buf.first.sof == first_pixel)) begin
        pixel_col = pixel_buf.first;
        pixel_buf.deq;
      end else begin // data missing so draw red
        pixel_col = red_pixel;
        $display("%05t: WARNING: pixel buffer is empty - drawing red", $time);
      end
    end
    de <= drawing;
    pixel_out <= pixel_col;
  endrule


  interface pixel_stream = toPut(pixel_buf);
  interface HDMIphysical phy;
    method HDMIColourChanT hdmi_r;  return hdmiCol(pixel_out.r);  endmethod
    method HDMIColourChanT hdmi_g;  return hdmiCol(pixel_out.g);  endmethod
    method HDMIColourChanT hdmi_b;  return hdmiCol(pixel_out.b);  endmethod
    method Bool hdmi_hsd;           return hsd;                   endmethod
    method Bool hdmi_vsd;           return vsd;                   endmethod
    method Bool hdmi_de;            return de;                    endmethod
    method Clock hdmi_dclk;	    return vidclk;		  endmethod
  endinterface

  method Action videoparams(VideoParamT p);
    vp <= p;
  endmethod
endmodule


//----------------------------------------------------------------------------


interface PixelStreamIfc;
  // AvalonMM slave interface for configuration register updates
  interface AvalonSlaveIfc#(4) avs;
  // AvalonMM master interface for DMA engine
  interface AvalonPipelinedMasterIfc#(DDR2_Addr_Width) avm;
  // Conduit for HDMI output
  interface HDMIphysical coe;
endinterface



(* synthesize,
   reset_prefix = "csi_clockreset_reset_n",
   clock_prefix = "csi_clockreset_clk" *)
module mkPixelStream(
  (* osc="csi_video_clk" *) Clock vidclk,
  PixelStreamIfc defaultIfc);

  VideoParametersIfc    vparams <- mkVideoParameters;
  BurstReadIfc       burst_read <- mkBurstRead;
  Reset                  vidrst <- mkAsyncResetFromCR(2, vidclk); // video reset
  HDMI_Timing_Ifc          hdmi <- mkHDMI_Timing(clocked_by vidclk, reset_by vidrst);

  Reg#(ResDimT)      num_pixels <- mkReg(0);
  Reg#(VideoParamT)     vp_sync <- mkSyncRegFromCC(unpack(0), vidclk);
  SyncFIFOIfc#(Pixel24bT) pix_sync <- mkSyncFIFOFromCC(256, vidclk); // size to use BRAM (M9K block)

  // connect pixel_stream from burst_reader to hdmi via clock crossing FIFO
  mkConnection(burst_read.pixel_stream, toPut(pix_sync));
  mkConnection(toGet(pix_sync), hdmi.pixel_stream);

  (* no_implicit_conditions *)
  rule forward_burst_params (True);
    VideoParamT vp = vparams.readParam();
    burst_read.params(vparams.readBase(), num_pixels);
    num_pixels <= extend(vp.xres) * extend(vp.yres);
  endrule

  rule forward_parameters_local_clock (True);
    vp_sync <= vparams.readParam(); // forward video parameters to HDMI timing driver
  endrule

  (* no_implicit_conditions *)
  rule forward_parameters_video_clock (True);
    hdmi.videoparams(vp_sync);
  endrule

  interface avs = vparams.avalon_slave;
  interface avm = burst_read.avalon_master_phy;
  interface coe = hdmi.phy;
endmodule


endpackage

