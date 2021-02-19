//
//  MachOTool.m
//  libffiDemo
//
//  Created by styf on 2020/9/2.
//  Copyright © 2020 styf. All rights reserved.
//

#import "MachOTool.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

@implementation MachOTool
/// 根据函数名返回函数指针
/// @param funcName 函数名称
+ (void *)funcPtrWithName:(NSString *)funcName {
    //第一次时可以使用_dyld_register_func_for_add_image(_rebind_symbols_for_image);
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        void *ptr = loopup_func_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i),[funcName cStringUsingEncoding:NSUTF8StringEncoding]);
        if (ptr != NULL) {
            return ptr;
        }
    }
    return NULL;
}

static void* loopup_func_for_image(const struct mach_header *header,intptr_t slide,const char *funcName) {
    Dl_info info;
    if (dladdr(header, &info) == 0) {
      return NULL;
    }
    
    //模块基地址  im li -o -f WeiPaiTangClient
//        printf("共享对象名称:%s--0x%lx \n",info.dli_fname,slide);
    segment_command_t *cur_seg_cmd;//临时变量
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command* symtab_cmd = NULL;
    struct dysymtab_command* dysymtab_cmd = NULL;
    
    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);//Load Commands的指针
    //遍历找出linkedit
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
      cur_seg_cmd = (segment_command_t *)cur;
      if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
        if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
          linkedit_segment = cur_seg_cmd; //取得__LINKEDIT段
        }
      } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
        symtab_cmd = (struct symtab_command*)cur_seg_cmd;//符号表、字符串表位置信息
      } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
        dysymtab_cmd = (struct dysymtab_command*)cur_seg_cmd;//动态符号表段
      }
    }

    uintptr_t segment_base = linkedit_segment->vmaddr - linkedit_segment->fileoff;
    uintptr_t linkedit_base = (uintptr_t)slide + segment_base;
    //通过linkedit_base 找到符号表、字符串表
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);//符号表
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);//字符串表
    //符号字符串61988:_myStaticFunc
    //符号字符串61997:-[WPTHomeHeaderCell wpt_uploadLotteryClickData]
    
    int i = 0;
    bool hasFind = false;
    for (i = 0; i < symtab_cmd->nsyms; i++) {
        if (strcmp(funcName, strtab + symtab[i].n_un.n_strx) == 0) {
//                printf("符号字符串%ld:%s\n",(long)i,(strtab + symtab[i].n_un.n_strx));
            hasFind = true;
            break;
        }
    }
    if (hasFind) {
        nlist_t myStaticFunc = symtab[i];//0x1019c6b84
            uintptr_t ptr = slide + myStaticFunc.n_value;//0x103f9ab84 函数地址
        //
        //    对地址反汇编 dis -a 0x00000001000110

//            void (*p)(int,double) = ptr;
//            p(3,4.5);
           return (void *)ptr;
    }
    return NULL;
}

@end
