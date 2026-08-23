#!/usr/bin/env node
// node --test tool/import_ip2region_test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { regionOf } from './import_ip2region.mjs';

test('境内:省份剥行政单位', () => {
  assert.equal(regionOf('中国', '福建省', 'CN'), '福建');
  assert.equal(regionOf('中国', '北京市', 'CN'), '北京');
  assert.equal(regionOf('中国', '内蒙古', 'CN'), '内蒙古');
  assert.equal(regionOf('中国', '新疆', 'CN'), '新疆');
});

test('港澳台:ip2region 的 ISO 码就是 CN,省份是长称', () => {
  assert.equal(regionOf('中国', '香港特别行政区', 'CN'), '香港');
  assert.equal(regionOf('中国', '澳门特别行政区', 'CN'), '澳门');
  assert.equal(regionOf('中国', '台湾省', 'CN'), '台湾');
});

test('🔴 未登记取值必须降级到"中国",绝不原样输出', () => {
  // ipv6_source.txt 真实存在的脏数据:城市被写进了省份列。
  // 原样输出 = 显示「IP属地:武汉」= 比承诺的省级粒度更细。
  assert.equal(regionOf('中国', '武汉', 'CN'), '中国');
  assert.equal(regionOf('中国', '广州', 'CN'), '中国');
  assert.equal(regionOf('中国', '', 'CN'), '中国');
  assert.equal(regionOf('中国', '0', 'CN'), '中国');
});

test('境外:走 CLDR,不用源文件里的英文名', () => {
  assert.equal(regionOf('Australia', 'Queensland', 'AU'), '澳大利亚');
  assert.equal(regionOf('United States', 'California', 'US'), '美国');
  assert.equal(regionOf('Japan', 'Tokyo', 'JP'), '日本');
});

test('保留段 / 无 ISO 码 → null(前端不展示,而不是展示"未知")', () => {
  assert.equal(regionOf('Reserved', 'Reserved', '0'), null);
  assert.equal(regionOf('x', 'y', ''), null);
  assert.equal(regionOf('x', 'y', 'ZZ'), null);
});
