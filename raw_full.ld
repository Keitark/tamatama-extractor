OUTPUT_ARCH(mips)
ENTRY(_entry)
SECTIONS {
  .entry 0xB4061000 : { KEEP(*(.entry)) }
  .text 0xB4061400 : { *(.text) }
  ASSERT(SIZEOF(.entry) == 0x400, "entry prefix changed")
  ASSERT(ADDR(.text) + SIZEOF(.text) <= 0xB4061A00, "code overlaps NAND data buffer")
  .data : { *(.data*) *(.sdata*) }
  .bss : { *(.bss*) *(.sbss*) *(COMMON) }
  ASSERT(SIZEOF(.data) == 0 && SIZEOF(.bss) == 0, "unreviewed runtime data")
  .padding 0xB40619FF : { BYTE(0) }
  /DISCARD/ : { *(.reginfo) *(.MIPS.abiflags) *(.pdr) *(.gnu.attributes) *(.comment) }
}
