# GeoRocker 遊戲參數總表

rockmech 模組所有可調參數，依學科分類。設定名都加上前綴 `rockmech_`（例如 `residual_phi` 是 `rockmech_residual_phi`）。
可以寫在世界資料夾的 `rockmech.conf`（優先）或 `minetest.conf`。完整英文說明與範圍見 `mods/rockmech/settingtypes.txt`。

「class_coal」欄是全班伺服器世界 `worlds/class_coal/rockmech.conf` 實際設定的值，空白表示用預設值。


## A. 地質


### A1 地層與岩性分布

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `surface_y` | 地表高程 y₀（地層深度由此起算） | 0 | 0 |
| `lith_mode` | 岩性分布方式：layers 依深度分層、zones 沿 x 分區 | layers | zones |
| `zone_width` | 分區模式：每區寬度 (m) | 80 | 100000 |
| `zone_order` | 分區模式：各區岩性順序 | — | shale |
| `replace_stone` | 地圖生成時把一般石頭換成本模組的岩性 | true |  |
| `strip_soil` | 剝除表土，露出岩盤 | false | true |
| `only_lithologies` | 其他天然方塊（礦石、冰等）也換成岩性 | false | true |

**岩性性質**（`config.lua` 的 `config.lithologies`，不是設定，改要改程式）

| 岩性 | 單位重 γ (kN/m³) | UCS (MPa) | 張力強度 σt (MPa) | Hoek-Brown mᵢ | 法向恢復 Rn | 切向恢復 Rt | 滾動阻力 | 破碎高度 (m) |
|---|---|---|---|---|---|---|---|---|
| 砂岩 | 25 | 60 | 4 | 17 | 0.35 | 0.85 | 0.4 | 4 |
| 頁岩 | 25 | 30 | 2 | 6 | 0.3 | 0.8 | 0.5 | 2.5 |
| 花崗岩 | 25 | 180 | 10 | 32 | 0.45 | 0.9 | 0.35 | 8 |
| 煤 | 14 | 15 | 1 | 8 | 0.25 | 0.75 | 0.5 | 2 |

煤另有 GSI 剖面 `top = 75`。分層模式預設：地表下 0–20 m 砂岩、20–60 m 頁岩、60 m 以下花崗岩。

### A2 地應力場

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `k0` | 側壓係數 K₀ = σh/σv（未指定方向性時） | 0.5 |  |
| `k_hmax` | 最大水平主應力係數 K_H = σH/σv | — | 1.5 |
| `k_hmin` | 最小水平主應力係數 K_h = σh/σv | — | 0.8 |
| `sigma_hmax0` | 構造應力項 σH₀ (MPa)，與深度無關 | 0 |  |
| `sigma_hmin0` | 構造應力項 σh₀ (MPa) | 0 |  |
| `sigma_hmax_azimuth` | σH 方位角 (°) | 0 | 90 |

### A3 不連續面（節理）幾何

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `joint_lattice` | 節理位態對齊的格點密度 D（位態誤差約 1°） | 8 | 8 |
| `joint_persistence` | 節理延續性：patch 片狀延續、face 逐面判定 | patch | patch |
| `joint_set_1` | 節理組 1：傾角, 傾向, 間距, 相位, 摩擦角 | — | 10,135,4,0,30 |
| `joint_set_2` | 節理組 2 | — | 60,0,4,0,30 |
| `joint_set_3` | 節理組 3 | — | 60,90,4,0,30 |
| `joint_set_4` | 節理組 4（額外） | — |  |
| `joint_set_5` | 節理組 5（額外） | — |  |
| `joint_set_6` | 節理組 6（額外） | — |  |

**預設節理組**（沒有 `joint_set_N` 設定時；`config.joint_sets`）

| 組 | 傾角 (°) | 傾向 (°) | 間距 (m) | 延續性 | 摩擦角 φ (°) |
|---|---|---|---|---|---|
| J1 | 10 | 135 | 4 | 0.95 | 25 |
| J2 | 70 | 40 | 3 | 0.8 | 32 |
| J3 | 80 | 300 | 5 | 0.7 | 30 |


### A4 礦體與地形

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `coal_seam` | 煤層：傾角, 傾向, 真厚度, y₀[, x₀, z₀] | — | 20,90,10,-15,30,0 |
| `coal_seam_lanes` | 煤層礦帶：帶寬, 最小帶號, 最大帶號（每帶一條相同煤層） | — | 160,-4,3 |
| `coal_joints` | 煤層帶不帶節理（false：節理組只在頁岩裡，煤層內與煤／頁岩接觸面都不是節理） | false | false |
| `lane_terrain` | 礦帶地形：脊高, 脊半寬, 山丘高, 山丘西界, 東界, 走廊 z, 漸變長 | — | 22,25,16,-55,0,-30,20 |
| `open_pit` | 露天坑：中心 x, z, 底半徑, 深度, 階高, 階寬[, 坡道坡度 %] | — |  |

**礦種**（`config.ores`）：煤，預設品位 191/255（75%），廢石母岩頁岩，基準價 $120/t（品位 100%），選礦回收率 90%。

## B. 岩石力學


### B1 岩體強度

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `model_scale` | 相似律 N：強度 ÷ N（模型尺度） | 1.0 | 1 |
| `gsi` | GSI 剖面（全部岩性）：深度:GSI, … | — |  |
| `gsi_sandstone` | GSI 剖面：砂岩 | — |  |
| `gsi_shale` | GSI 剖面：頁岩 | — | 50 |
| `gsi_granite` | GSI 剖面：花崗岩 | — |  |
| `rockmass_d` | Hoek-Brown 擾動因子 D | 0 |  |
| `failure_strength_scale` | 強度縮放（舊版相容） | 1.0 |  |
| `overhang_scale` | 懸空張力強度縮放（舊版相容） | 1.0 |  |
| `overhang_tensile_other` | 非岩性方塊的張力強度 (MPa) | 2.0 |  |
| `failure_gamma_other` | 非岩性實心方塊的單位重 γ (kN/m³) | 20 |  |

### B2 破壞判定

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `failure_enabled` | 開啟軸差破壞（Hoek-Brown）判定 | true |  |
| `induced_enabled` | 只判定開挖誘發的破壞（自然地形視為平衡） | true |  |
| `induced_touch_max` | 開挖碰到的既有懸空，多大以內會掉 (格) | 200 |  |
| `weakness_enabled` | 開啟節理面滑動（Jaeger 弱面） | true |  |
| `weakness_c` | 節理凝聚力 c_j (MPa) | 0.05 | 0 |
| `weakness_phi` | 節理摩擦角 φ_j (°) | 30 |  |
| `weakness_daylight` | 滑動需節理面在開挖面出露（daylight） | true |  |
| `weakness_lateral_limit` | 平面滑動的側向限制角 (°) | 20 |  |
| `weakness_wedge` | 兩組節理交線的楔形滑動 | true |  |
| `weakness_max_spacing` | 間距小於此值的節理組逐格判定 (m) | 100 | 1.5 |
| `keyblock_enabled` | 開啟關鍵塊體判定 | true |  |
| `keyblock_c` | 關鍵塊體節理凝聚力 (MPa) | 0 |  |
| `keyblock_clamp` | 關鍵塊體的應力夾持係數 | 0.5 |  |
| `keyblock_mass` | 大範圍塊體滑動 | true |  |
| `keyblock_mass_clamp` | 大範圍滑動的應力夾持係數 | 0 |  |
| `overhang_enabled` | 開啟懸空頂板斷裂判定 | true |  |
| `overhang_joints` | 節理切斷懸空頂板 | true |  |
| `overhang_terzaghi_gsi_a` | Terzaghi 岩載：k = 0 時的 GSI | 85 |  |
| `overhang_terzaghi_gsi_b` | Terzaghi 岩載：中間 GSI | 50 |  |
| `overhang_terzaghi_k_b` | Terzaghi 岩載：中間 GSI 的 k | 0.35 |  |
| `overhang_terzaghi_gsi_c` | Terzaghi 岩載：低 GSI | 25 |  |
| `overhang_terzaghi_k_c` | Terzaghi 岩載：低 GSI 的 k | 1.1 |  |
| `shear_enabled` | 懸空頂板剪切判定 | true |  |
| `shear_k` | 剪力強度係數 k | 2 |  |
| `shear_max_span` | 頂板載重傳遞跨距 (格) | 32 |  |
| `stability_enabled` | 連通性（懸空塊）判定 | true |  |
| `stability_rigid` | 剛體塊整塊掉落 | true |  |
| `fswarn_max` | 警戒裂紋：1 < FS < 此值時顯示 | 2 |  |

### B3 落石與碎石

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `rockfall_enabled` | 開啟翻滾落石 | true |  |
| `rockfall_rn` | 非岩性表面法向恢復係數 Rn | 0.30 |  |
| `rockfall_rt` | 非岩性表面切向恢復係數 Rt | 0.75 |  |
| `rockfall_mu_roll` | 非岩性表面滾動阻力 | 0.55 |  |
| `rockfall_impact_speed` | 撞擊碎裂速度門檻 (m/s) | 2.0 |  |
| `rockfall_stop_speed` | 停止速度 (m/s) | 0.4 |  |
| `fallbreak_enabled` | 掉落的岩塊依落下高度破碎成碎石 | true |  |
| `fallbreak_break_height` | 非岩性岩塊的破碎高度 (m) | 4.0 |  |
| `slope_enabled` | 碎石依殘餘摩擦角流動 | true |  |
| `residual_phi` | 鬆散材料（碎石、鬆土）的殘餘摩擦角 φr (°)，看到的安息角由它決定（舊名 `slope_angle` 也讀） | 35 |  |
| `slope_rain_drop` | 時雨量達 `rain_max` 時，鬆土殘餘摩擦角降低幾度（照時雨量比例、照土的比例）；岩石碎石不受影響 | 10 |  |
| `slope_rain_max` | 時雨量上限 (mm/h)，台灣颱風的量級；降雨弱化跟 時雨量 / rain_max 成正比 | 100 |  |
| `slope_rain_c_loss` | 時雨量達 `rain_max` 時，表土凝聚力降低的比例（自立高度 H_c 跟著降） | 0.35 | 100 mm/h 時 H_c ≈ 1.25 m |
| `mapgen_topsoil` | 產生地圖時天然岩石上鋪表土（任何世界都適用）：山坡 1–3 m（礦帶的礦區山丘 0.25–1 m）、平地 0.25–0.75 m、山腳漸薄的坡腳；礦石露頭不鋪；山坡稀疏種樹 | true |  |
| `outcrop` | 山坡裸露岩面（露頭）的面積比例：一片一片約 10–20 m，邊緣的土漸薄，不種樹 | 0.2 | 0–0.9 |
| `topsoil_c` | 表土（根系）的凝聚力 (kPa)：應力解的土元素用它（Mohr-Coulomb，張力截斷 c·cot φ）；關掉土元素時改用自立高度 H_c = 4c/γ·tan(45°+φ/2) | 10 | H_c ≈ 3.8 m |
| `rubble_squeeze` | 每次載重事件擠出的碎石量 | 0.125 |  |
| `compact_phi` | 壓實碎石的摩擦角 (°) | 75 |  |

### B4 應力解（有限元素）

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `fem_nu` | 卜松比 ν | 0.25 |  |
| `fem_rubble_e` | 碎石勁度比（相對完整岩石） | 0.1 |  |
| `fem_drive` | 應力解驅動開挖後的破壞 | true |  |

## C. 採礦工程


### C1 鑽孔與爆破

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `blast_enabled` | 開啟爆破破碎 | true |  |
| `blast_ucs_ref` | 爆破參考 UCS (MPa) | 60 |  |
| `blast_ucs_exp` | 爆破範圍隨強度的指數 | 0.167 |  |
| `blast_inner` | 拋擲區比例 | 0.5 |  |
| `blast_damage_t` | 爆破擾動帶厚度 (m)：破碎區外這一圈岩石用 Hoek-Brown 的 D 打折（每孔 1 條乳膠炸藥 0.5、2 條以上或貼面 0.8、ANFO 1.0） | 1 |  |
| `blast_charge_radius` | 每條乳膠炸藥的作用半徑 (m) | 2.0 |  |
| `blast_max_cartridges` | 每孔最多藥條數 | 4 |  |
| `blast_hole_depth` | 鑿岩機孔深 (m) | 2 |  |
| `blast_hand_max_depth` | 手持鑿岩機最大孔深 (m) | 4 |  |
| `blast_surface_factor` | 無圍束（裸露）裝藥係數 | 0.3 |  |
| `blast_confine_factor` | 圍束係數 | 0.75 |  |
| `blast_free_face_k` | 自由面加成 | 1.0 |  |
| `blast_anfo_radius` | ANFO 每段作用半徑 (m) | 2.5 |  |
| `blast_anfo_stemming` | ANFO 填塞長度 (m) | 1.5 |  |
| `blast_drill_time` | 鑽孔時間 (s) | 1.5 |  |
| `blast_fuse_time` | 導火索時間 (s) | 4 |  |
| `blast_detonator_range` | 起爆器距離 (m) | 30 |  |
| `blast_detonator_delay` | 起爆器倒數 (s) | 5 |  |
| `blast_hole_interval` | 孔間延時 (s) | 0.1 |  |

### C2 支護

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `support_shotcrete_p` | 噴凝土等效支撐壓力 pᵢ (MPa) | 0.01 |  |
| `support_bolt_grip` | 岩栓握裹力 (kN/m) | 200 |  |
| `support_bolt_yield` | 岩栓鋼材降伏 (kN) | 360 |  |
| `support_post_d` | 木柱直徑 d (m)；承載力 P = min(壓碎 σc·A, 尤拉挫屈 π²EI/L²) | 0.2 |  |
| `support_post_ucs` | 木材順紋抗壓強度 σc (MPa) | 20 |  |
| `support_post_e` | 木材彈性模數 E (MPa) | 10000 |  |
| `support_post_max_len` | 木柱最長 (m)：從地板長到頂板 | 6 |  |
| `support_post_fem_area` | 應力解裡木柱的等效斷面積 A_eff (m²)：木柱格勁度 = 岩石 × A_eff / 1 m²；軸力 σv × 1 m² 超過承載力就壓斷（真實 0.031 m² 太軟，假設性放大） | 0.5 |  |

### C3 裝載與運輸

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `haul_max_grade` | 礦卡最大爬坡角 (°) | 17 |  |
| `vehicle_slide_mu` | 車輛在碎石上的摩擦係數 | 0.5 |  |
| `compact_mass` | 交通壓實：最小總重 (t) | 10 |  |
| `rr_loose` | 滾動阻力：鬆碎石、土 (%)（噴凝土 1.5、壓實碎石／岩盤 2、車轍每 cm +0.6，寫死）；輪胎車滿載在 RR＋坡度 ≤ 4 % 時才跑得到極速 | 4 |  |
| `compact_passes` | 交通壓實：通過次數 | 4 |  |
| `ahs_tail_gap` | 無人卡車車尾離怪手的距離 (m) | 1.5 |  |
| `ahs_back_in` | 無人卡車倒車距離 (m) | 3 |  |
| `ahs_follow` | 怪手移動多遠卡車重新停車 (m) | 6 |  |
| `ahs_max_dist` | 怪手離路線起點最遠 (m) | 60 |  |
| `cart_blocks` | 手推車載量 (塊) | 3 |  |
| `shotcrete_speed` | 在噴凝土路面的車速倍數 | 1.5 |  |

**車輛規格**（各 `vehicle_*.lua` 與 `V.MASS`，不是設定）

| 車輛 | 自重 (t) | 載量 (m³) | 速度 (m/s) | 備註 |
|---|---|---|---|---|
| 手推車 | 0.2 | 3 塊 | 2.5 | 人推 |
| 休旅車 | 2.5 | — | 6 | 四驅，爬坡 30° |
| 卡車 | 15 | 12 | 5.0 |  |
| 礦卡 | 70 | 36 | 4.5（直線加速到 9） | 最大爬坡見 haul_max_grade |
| 挖土機 | 20 | 鏟斗 4 | 1.4 | 爬坡 35°；長距離用平板拖車載 |
| 礦用挖土機 | 100 | 鏟斗 12 | 1.0 | 手臂約 15 m |
| 推土機 | 20 | — | 2.5 | 爬坡 30° |
| 平板拖車 | — | 載車 ≤ 60 t | 4（直線加速到 12；載車上限 8、加速度減半） | 載怪手、推土機、報廢的車 |
| 露天鑽機 | 25 | — | 1.2 | 孔深 3–10 m |
| 鑽堡 | 30 | — | — | 依設計圖鑽工作面 |
| 裝藥台車 | 20 | — | — |  |
| ANFO 裝藥車 | 30 | — | 5.0 |  |
| 連續採礦機 | — | 料倉 60 | 1.4（切削 0.6） | 切削寬 5 m、卸料 6 m³/s |

### C4 輸送、破碎與選礦

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `conveyor_rate` | 輸送帶運量 (t/s) | 4 |  |
| `conveyor_speed` | 輸送帶帶速 (m/s) | 2 |  |
| `conveyor_max_angle` | 輸送帶最大傾角 (°) | 16 |  |
| `crusher_rate` | 破碎站處理能力 (t/s) | 2 |  |
| `crusher_big_rate` | 大型破碎站處理能力 (t/s) | 10 |  |
| `plant_rate` | 選礦場進料速度 (t/s) | 3 |  |
| `plant_recovery` | 選礦場煤回收率 | 0.95 |  |
| `plant_misplaced` | 岩石誤入精煤的比例 | 0.1 |  |
| `plant_bin` | 選礦場儲料塔容量 (t) | 50 |  |
| `plant_load_rate` | 放料臂裝車速度 (t/s) | 4 |  |
| `plant_reach` | 放料臂搆得到的距離 (m) | 10 |  |

## D. 經濟


### D1 資金與費用

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `career_start` | 開局資金 ($) | 23000 |  |
| `crusher_fee` | 破碎處理費 ($/t) | 30 |  |
| `operator_wage` | 怪手操作員日薪（$／交易日；按雇用時間比例、只在組員在線時扣，列在日結表的人事費） | 3000 |  |
| `diesel_price` | 柴油價（$/L）。燃料費（fuel.lua）：引擎發動（有人駕駛、無人駕駛在跑、怪手有操作員）才耗油，空車停著不算。耗油 = 比油耗 0.22 L/kWh × 額定功率 × 負載率；負載率 = 總重 × g ×（滾動阻力 0.03 × 車速 + 爬升速度）÷ 額定功率，怠速最少 0.1、作業中最少 0.6。額定功率在 `config.engine_kw`（卡車 300 kW、礦卡 1000 kW、怪手 120 kW…）。直接從帳戶扣，列在日結表的燃料費 | 50 |  |
| `dump_fee` | 廢石棄置費 ($/t) | 0 |  |
| `rubble_density` | 計價用碎石密度 (t/m³) | 2.5 |  |

**交貨方式**（delivery.lua）：人身上只放小東西。車輛買了停在自己營地東南邊的交車區（營地中心往東 10–36 m、z = −24 ~ −42；北排車頭朝北、南排車頭朝南，左右隔 1 m；沒空位就不賣）；破碎站、選礦場、輸送帶給「施工單」，拿著對地面右鍵施工，施工範圍裡有人或車就不施工（預覽框變紅）。

**設備價格**（`config.shop`，可用 `rockmech_price_<key>` 覆寫）：鎬 免費、鏟 $100、手推車 $500、鑿岩機 $500、起爆器 $500、乳膠炸藥 ×10 $500、ANFO ×10 $1,000、岩栓 ×10 $300、噴凝土 ×10 $800、斧頭 $100（砍樹：整棵倒下變原木）、木柱 ×10 $200（頂到岩石頂板才算支撐：2 m 約 628 kN、4 m 約 484 kN、6 m 約 215 kN）、木板 ×10 $100（薄板）、木板半格 ×10 $100（建材，不算支撐；營地鋸木台：原木 1 → 木柱 2／木板 4／半格 8；木工桌：木板做牆板、樓梯、門、活板門、柵欄、梯子）、地質羅盤 $200、野帳本 $10（對岩芯箱右鍵判讀，每公尺 0.5 秒，最多記 20 孔；記下的欄位照判讀當時的能力）、置物箱 $200（施工單，32 格，全組共用）、無人機 $2,000、指揮無人機 $5,000（無人機＋對講機：飛行中左鍵指揮怪手、打開卡車的無人駕駛設定，指揮距離 128 m）、休旅車 $3,000、輸送帶 ×10 $1,000、油壓破碎錘 $20,000（怪手改裝套件：鏟斗空的時候空白鍵切換，對岩石按 E 敲碎，時間 = UCS × rockmech_breaker_s_per_mpa（0.05 s/MPa））、自動駕駛模組 $8,000（每台卡車／礦卡要裝一個才能無人駕駛）、卡車 $10,000、怪手 $15,000、破碎站 $20,000、選礦場 $30,000、裝車料斗 $25,000（施工單；36 m³，頂上格柵接輸送帶，放料臂 4 m³/s 裝 plant_reach 內停著的卡車，無人卡車可在臂下等著裝）、推土機 $35,000、裝藥車 $40,000、裝藥台車 $40,000、鑽機 $50,000、鑽孔台車 $60,000、礦卡 $150,000、礦用怪手 $200,000、大型破碎站 $300,000、連續採礦機 $1,500,000（終極目標）。

收入 = 噸數 × 品位 × 回收率 × 當日礦價 × 收購比例 − 噸數 ×（1 − 品位）× 處理費。收購比例：教學地圖 `coal_yard_ratio`（0.7），其他地圖 1。

### D2 礦價（對數 Ornstein–Uhlenbeck）

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `price_period` | 交易日長度 (s) | 1200 |  |
| `price_vol` | 每日波動 σ | 0.08 |  |
| `price_revert` | 均值回歸 θ | 0.15 |  |
| `price_min` | 價格下限（基準價的倍數） | 0.5 |  |
| `price_max` | 價格上限（基準價的倍數） | 2 |  |

## E. 數值計算與效能


### E1 搜尋範圍、上限與時間預算

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `failure_radius` | 軸差破壞檢查半徑 (格) | 6 |  |
| `failure_secondary_factor` | 次要檢查半徑係數 | 0.5 |  |
| `failure_window` | 載重分攤視窗半寬 (格) | 4 |  |
| `failure_overburden_scan` | 覆土掃描高度 (格) | 64 |  |
| `failure_initial_scan_max` | 初始應力掃描高度上限 (格) | 512 |  |
| `failure_max_cascade` | 連鎖破壞最多輪數 | 5 |  |
| `failure_cascade_delay` | 連鎖破壞間隔 (s) | 0.6 |  |
| `failure_interval` | 軸差破壞檢查最快幾秒一次（期間的觸發合併成一批；連鎖每輪也至少隔這麼久） | 5 |  |
| `failure_budget_ms` | 每次檢查時間預算 (ms)；超過 3 倍才記 log | 5 |  |
| `keyblock_max_cells` | 關鍵塊體最大格數 | 500 |  |
| `keyblock_mass_radius` | 大範圍滑動搜尋半徑 (格) | 28 |  |
| `keyblock_mass_max` | 大範圍滑動最大格數 | 8000 |  |
| `keyblock_mass_floods` | 每次檢查的候選數 | 48 |  |
| `stability_radius` | 連通性搜尋半徑 (格) | 12 |  |
| `stability_max_voxels` | 最大掉落群格數 | 2000 |  |
| `stability_rigid_max` | 剛體塊最大格數 | 128 |  |
| `stability_budget_ms` | 連通性檢查時間預算 (ms) | 5 |  |
| `overhang_radius` | 懸空檢查半徑 (格) | 16 |  |
| `overhang_max_voxels` | 懸空最大格數 | 30000 |  |
| `rockfall_max_active` | 同時翻滾的落石上限 | 64 |  |
| `rockfall_max_time` | 落石最長翻滾時間 (s) | 20 |  |

### E2 應力解（有限元素）

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `fem_enabled` | 開啟背景應力解（hex8 彈性） | true |  |
| `fem_radius` | 求解半徑 (格) | 12 |  |
| `fem_coarse` | 遠場粗元素大小 (格) | 2 |  |
| `fem_coarse_blend` | 粗元素剪力積分係數 | 0.1 |  |
| `fem_active_range` | 玩家多遠內才解 (m) | 64 |  |
| `fem_tol` | 收斂容許誤差 | 0.001 |  |
| `fem_max_iter` | 最大迭代次數 | 1500 |  |

## F. 遊戲操作


### F1 手工具與挖掘時間

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `hand_ore_time` | 徒手敲一格礦石 (s) | 60 |  |
| `hand_rubble_time` | 徒手拿一格碎石 (s) | 4 |  |
| `pick_rock_time` | 鎬子挖一格岩石 (s) | 8 |  |
| `pick_rubble_time` | 鎬子拿一格碎石 (s) | 2 |  |
| `shovel_time` | 鏟子鏟一格碎石 (s) | 0.5 |  |
| `fswarn_dig_min` | 有裂紋的岩石挖掘時間倍數下限 | 0.25 |  |

## G. 介面、音效與顯示


### G1 音效

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `rubble_sound_gain` | 碎石聲音量 | 1 |  |
| `vehicle_sound_gain` | 車輛引擎、無人機音量 | 1 |  |
| `fswarn_sound_gain` | 裂紋聲音量 | 3 |  |
| `fswarn_sound_distance` | 裂紋聲傳播距離 (m) | 32 |  |

### G2 節理跡線顯示

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `jointtex_enabled` | 顯示節理跡線 | true |  |
| `jointtex_style` | 跡線樣式：plane／edges／mesh | plane | mesh |
| `jointtex_mesh_range` | mesh 樣式的顯示範圍 | 3 |  |
| `jointtex_mesh_width` | mesh 線寬 (m) | 0.06 |  |
| `jointtex_mesh_overlay` | mesh 疊加檢查 | false |  |
| `jointtex_max_lines` | 每格最多幾條跡線 | 2 |  |
| `jointtex_plane_res` | 跡線貼圖解析度 | 32 |  |
| `jointtex_plane_width` | 跡線寬度 | 1.5 |  |
| `jointtex_line_color` | 跡線顏色 | #000000 |  |
| `jointtex_line_alpha` | 跡線不透明度 | 170 |  |
| `jointtex_line_width` | 跡線粗細 | 1 |  |
| `jointtex_face_color` | 節理面染色 | #8a5a2a |  |
| `jointtex_face_ratio` | 節理面染色強度 | 110 |  |

## H. 班級伺服器


### H1 經營模式與分組

| 參數 | 意義 | 預設 | class_coal |
|---|---|---|---|
| `career` | 經營模式 | false | true |
| `career_teams` | 組數 | 8 | 7 |
| `career_site_spacing` | 營地間距（沒設礦帶時）(m) | 150 |  |
| `career_roster` | 名單檔 | students.csv |  |
| `career_roster_only` | 只有名單上的帳號能登入 | true |  |
| `career_camp_dx` | 營地離礦帶中心往東 (m) | 0 | 20 |
| `daily_restart` | 每日定時重開時間 | — | 04:00 |
| `drone_range` | 無人機最大飛行距離 (m) | 200 |  |

---

共 187 個設定。
