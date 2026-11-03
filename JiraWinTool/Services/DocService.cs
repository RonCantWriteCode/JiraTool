namespace JiraWinTool.Services;

/// <summary>文档生成服务（移植自 Swift DocService.swift）</summary>
public static class DocService
{
    public static (string Title, string Content) GenerateDoc(string reqId, string reqName, string categories, string[] tags, string description)
    {
        var now = DateTime.Now;
        var timeall = now.ToString("yyyy-MM-dd HH:mm:ss");
        var nianyue = now.ToString("yyyy-MM");
        var nianyueri = now.ToString("yyyy-MM-dd");

        var title = $"{nianyue}┃({reqId})《{reqName}》【{categories}】";
        var tagsStr = string.Join(", ", tags);

        var content = $@"---
title: 【{categories}】{reqName}（{reqId}）
author: 吴浩鹏
date: {timeall}
tags: [{tagsStr}]
categories: {categories}
description: {description}
  <p>（ http://jira.sinosafe.com.cn/browse/{reqId} ）</p>
toc: true
---
[toc]

# 【{categories}】{reqName}（{reqId}）
<sup class=""footnote-ref-left""  data-index=""1"" ></sup>

<div class=""footnotes-library"" style=""display: none;"">
  <div class=""footnote-item"" data-index=""1"" >
1. 对应jira：<a href=""http://jira.sinosafe.com.cn/browse/{reqId}"" title=""{reqId}"">{reqId}</a></div></div>



| **版本号** | **版本说明/变更理由/变更内容** | **作者** | **日期**   | **备注** |
| ---------- | ---------------------------------- | -------- | ---------- | -------- |
| V1.0       | C：初始创建                        | 吴浩鹏   | {nianyueri} |          |
# 引言
## 编写目的

## 项目背景

## 定义

## 参考资料

# 总体设计
## 需求概述
### 功能需求：

###  非功能性需求：

## 系统设计图
### 跨系统流程图
";

        return (title, content);
    }
}
