# ZORU — Laporan produksi

Pembaruan ini mempertahankan alamat proxy mainnet, kepemilikan token, aturan penambangan, pembagian reward, dan batas suplai. Pemindahan dan pembersihan seluruh catatan lama selesai pada 4 November 2026. Implementasi akhir sudah aktif; penambangan dan klaim dibuka kembali setelah pemeriksaan on-chain.

## Alamat mainnet

Jaringan EVM menggunakan chain **6736**, dengan identitas native `f9f432b1851b5c179d2091a96f593aaed50ec7466b74f89301f957a83e56ce1f`.

| Kontrak | Alamat tetap |
| --- | --- |
| Token | `0xb972753d17C5131D127B6c22DDE79B91a3132D03` |
| Ledger | `0xFf53a9079C2853C39C5adBfca788cb0f12aCFF03` |
| Engine | `0x9eD52C07691Cd26758ed1Ebe05d86698a9e54e8C` |
| Beacon | `0x562249B5c3922fAfa31f350EfDb89E4F3F9a82fE` |
| Koordinator | `0xF5A9911A70aD0D9456C4228c08B74d161786F410` |

Implementasi berikut sudah aktif pada proxy yang sama. Bytecode dan alamat implementasi diperiksa melalui RPC lokal serta RPC publik.

| Implementasi | Alamat | Transaksi deployment |
| --- | --- | --- |
| Ledger | `0xc1778bac309fa6e79536f9635a09d401f6d0c98d` | `0x13a52312ab56336654a861e0a0fe044490130ec04e6711c0106fba1b458c7470` |
| Beacon | `0xbb2c5f1a6fdda54f8c67e954822be4296ae8e055` | `0xa5af0b866980cc25dc29e0da9aab795262c50f327e31aa70004e8f3cef0eb600` |

Sumber kontrak yang diperiksa adalah [37cb4b22b82ba478050969b40a24c3b110fe6f0f](https://github.com/zoruco/zoru-pow/commit/37cb4b22b82ba478050969b40a24c3b110fe6f0f). Sumber miner yang dibangun dan diuji adalah [114032ff5005570ef35d836b6eabe471d538e969](https://github.com/zoruco/zoru-miner/commit/114032ff5005570ef35d836b6eabe471d538e969). Perbaikan pemulihan pelaksanaan tersedia pada [d2c3d31](https://github.com/zoruco/zoru-pow/commit/d2c3d31).

## Penyimpanan dan RAM

Penyebab utama pertumbuhan RAM adalah jumlah baris penyimpanan native: dua baris untuk proof yang belum diklaim, tiga setelah diklaim, sembilan untuk epoch, serta dua baris cache beacon untuk setiap epoch yang dipublikasikan. Publikasi randomness autentik untuk epoch historis juga dapat menambah cache tanpa adanya proof penambangan.

Pengukuran pada lingkungan terisolasi dengan WASM native yang sama menunjukkan biaya **346 byte per baris**. Tabel penyimpanan pertama menambah **112 byte**. Penggantian nilai dalam baris yang sudah ada tidak menambah RAM; penghapusan baris mengembalikan RAM. Transaksi yang gagal di EVM dan panggilan yang hanya menghasilkan log tidak menambah RAM pada akun yang sudah tersedia.

| Catatan | Sebelum | Penyimpanan akhir |
| --- | ---: | ---: |
| Proof belum diklaim | 692 byte | 346 byte |
| Proof sudah diklaim | 1.038 byte | 346 byte |
| Epoch | 9 baris | 3 baris |
| Cache beacon | 692 byte per epoch publikasi | 3 baris tetap yang digunakan kembali |
| Perubahan status klaim | Menambah satu baris proof | Mengubah baris proof yang sama |

Satu catatan proof menyimpan penerima, epoch, indeks, dan status klaim. Riwayat kepemilikan serta perlindungan terhadap proof ganda tetap tersedia setelah pembayaran. Penghematan tidak bergantung pada server baru, penerbit komitmen, atau distribusi Merkle. Pilihan arsitektur, transaksi pengukuran, serta model kapasitas tersedia di [Native storage](NATIVE_STORAGE.md).

## Penyelesaian mainnet

Inventaris beku pada blok **11.620.508**, hash `0xa2a8198b05f84505ab73985eec6c511711fdc8ee5b9bff4f8c9f3e8486853428`, mencakup **6.892 proof**, **3.057 epoch**, dan **5.295 epoch publikasi beacon**. Sidik inventaris adalah `e6dd391646e7eee0d228ee0d37f6c52e220c933075e71003e14fbcdfaf51cdf3`. Seluruh proof dan epoch dipindahkan, dicocokkan, kemudian sumbernya dihapus dalam batch yang dapat dilanjutkan setelah interupsi.

Pemindaian native lengkap mencatat Ledger **48.184 → 16.080 baris** dan Beacon **10.339 → 5 baris** sebelum cache berjalan diisi kembali. Tidak ditemukan baris tidak dikenal, hilang, atau berbeda. Cache berjalan kemudian memakai tiga baris tetap. Penghapusan menghasilkan **14.683.548 byte** pengembalian RAM pada baris protokol. Penggunaan global setelah persiapan adalah **26.170.208 byte** dan setelah aktivasi akhir dalam keadaan dijeda **11.489.082 byte**; selisih global **14.681.126 byte** mencakup perubahan administrasi dan penggunaan akun bersama. Kuota **26.200.530 byte**, sehingga ruang tersedia saat pemeriksaan tersebut **14.711.448 byte**.

Pada pemeriksaan sesudah pembukaan, blok **11.639.725**, seluruh kepemilikan dan indeks 6.892 proof lama serta isi 3.057 epoch tetap cocok. Semua **22 proof lama yang belum diklaim**, senilai **60 ZORU**, sudah dibayar oleh pekerja klaim otomatis. Terdapat **12 proof baru**, **delapan epoch baru**, lima di antaranya sudah disegel, dan tujuh proof baru sudah dibayar pada snapshot itu. Penolakan klaim ganda dibuktikan melalui `eth_call` dengan error tepat `NotClaimable()`; tidak ada transaksi duplikat yang dikirim. Snapshot ini bukan angka berjalan terbaru.

| Tindakan | Hash transaksi mainnet |
| --- | --- |
| Aktivasi akhir | `0x8d2b7b1a6b201af5a0f5a92efa40ec1075bf764a005658de7fd54fb90ab0c09a` |
| Pembersihan delapan penanda | `0x1b73f3d7750d097842bff774bdc2f32fbc4339a9c697bd4adb0c1ab3ccceae8e` |
| Pembersihan proof terakhir | `0xe304392362d5434b351b61ef9d8d7e9b500c827c77056c051661859155afd8a4` |
| Pembersihan epoch terakhir | `0xe95644137e427f57bb68a762ad1cfa3f0fecf3a226144097f62b652619530a50` |
| Pembersihan cache terakhir | `0x02cc3ec08f68b424d6203f0621d6daebad9e99c7f54cff114e318fbb4b0786a4` |
| Membuka klaim | `0xb7de8231664057da22a532c6b8035cabb021604531b9ee67385b70c90b80176e` |
| Membuka penambangan | `0x5ffe2e8933a432fa6896056e8a4cecd9474a207a8f1d19fdefbb4007a33bf4b6` |
| Proof baru terkonfirmasi | `0x42d94850dade85ebf6378da12a821f9e3867483096d62de00dbc05baf3817050` |
| Penyegelan epoch baru | `0x46afd9d1972f9424a8d5bf5fdaa7f0128c42e010807b98042959b856541b741c` |

[Catatan verifikasi mainnet](../release/mainnet-verification.json) memuat 991 receipt pelaksanaan, daftar transaksi klaim lama, pencocokan pembayaran, dan pemeriksaan sesudah aktivasi. Biaya gas receipt pelaksanaan: **11,30172525 VEX** dari signer owner dan **178,45501335 VEX** dari signer operasional; seluruh transaksi mempunyai nilai transfer EVM nol. Pengeluaran RAM **2,5000 VEX** dan alokasi **650 VEX testnet** menggunakan izin khusus pemilik yang tercatat terpisah.

## Keamanan dan pembayaran

Pemeriksaan mencakup Token, Ledger, Engine, Beacon, proxy, ProxyAdmin, koordinator upgrade, dan miner Rust. Temuan beserta hasil pemeriksaannya tersedia di [Protocol review](REVIEW.md).

Penyimpanan akhir mempunyai satu jalur pencatatan proof dan reward. Pembacaan sumber lama, jalur cadangan migrasi, dan fungsi pemindahan sementara tidak disertakan dalam implementasi akhir. Lokasi penyimpanan sebelumnya tetap dicadangkan agar tata letak proxy aman; nilainya dikosongkan setelah penggantinya terverifikasi. Delapan posisi penghitung dan penanda migrasi sudah diverifikasi kosong sebelum aktivasi akhir dan diperiksa kembali sesudah penambangan dibuka.

Validasi resmi OpenZeppelin **1.47.0** meluluskan enam perbandingan tata letak tanpa pengecualian yang melewati pemeriksaan. Mapping proof awal tetap pada slot **13**, mapping epoch awal pada slot **12**, dan mapping baru ditambahkan pada slot **16** serta **21**. Hasil tersedia di [storage-validation.json](../release/storage-validation.json).

Verifikasi beacon tetap menggunakan tanda tangan drand yang diautentikasi. Pengujian mencakup jadwal round, domain tanda tangan, kunci publik tepercaya, titik kurva, subgroup, pairing precompile, vektor RFC 9380 independen, dan publikasi native dengan tanda tangan sebenarnya. Tidak ditemukan cara melewati verifikasi pada pengujian tersebut. Dependensi BLS upstream bersifat eksperimental dan belum memiliki audit kriptografi independen; pengujian ini tidak menggantikan audit tersebut.

## Miner

Pemulihan nonce menelusuri blok yang benar-benar mengonsumsi nonce, termasuk transaksi di luar jendela pencarian terbaru. Jurnal hanya diselesaikan setelah receipt transaksi pengganti terbukti kanonis. Respons pengiriman yang hilang tidak menyebabkan transaksi baru ditandatangani secara membabi buta.

Miner mempertahankan jurnal sebelum pengiriman, memverifikasi identitas jaringan pada RPC cadangan, menghormati kedua kontrol jeda kontrak, dan mengurangi pembacaan ulang proof yang sudah final. Hashing menggunakan kembali bagian challenge yang tetap. Pengukuran lokal tiga sampel, masing-masing 250.000 hash, menghasilkan median **620.667** menjadi **956.444 hash/detik** pada host pengujian; hasil ini bergantung pada beban host dan bukan jaminan throughput jaringan.

Saat pelaksanaan mainnet, beberapa pengiriman mendapat pengakuan eksekusi dari API native tetapi belum menghasilkan receipt EVM kanonis dalam batas waktu. Nonce native dan EVM tetap belum terpakai. Setelah pemeriksaan lintas RPC, byte transaksi bertanda tangan yang sama dikirim kembali dan terkonfirmasi tanpa tanda tangan atau nonce baru. Pemulihan berikutnya dibatasi pada dua percobaan dalam jendela pemeriksaan; transaksi tetap disimpan jika hasilnya belum dapat dibuktikan. Pengakuan relay diperlakukan terpisah dari konfirmasi blok dan finalitas native.

Log native juga mencatat `leeway_deadline_exception` saat kapasitas CPU relay `miner.wind` hampir penuh. Pemilik menambah alokasi CPU; pemeriksaan sesudahnya menunjukkan sekitar 38,4 detik tersedia, dan transaksi yang tertahan berhasil dikonfirmasi dengan byte yang sama. Kapasitas CPU relay perlu dipantau terpisah dari RAM `vex.evm`.

Pemeriksaan lanjutan menemukan publikasi beacon dapat tertahan karena permintaan epoch lama menumpuk saat jaringan melambat. Antrean tersebut dihapus; satu penulis mengambil epoch yang berlaku saat publikasi, memeriksa ulang batas epoch, dan memakai jeda percobaan terbatas. Pengujian native dengan gangguan 75 detik serta penundaan tiga detik berhasil melanjutkan penambangan pada tiga epoch: 15 proof diterima dan tujuh klaim otomatis. Enam error dalam pengujian itu berasal dari gangguan yang sengaja disuntikkan dan tetap dicatat. Sumber perubahan tersedia pada [10bd546](https://github.com/zoruco/zoru-miner/commit/10bd5463bef6d3f47079f4de9e7e534fd2b7a011).

Pengiriman melalui RPC publik kemudian ditolak oleh batas CPU native: kebutuhan **18.074 μs**, sedangkan batas yang diberikan untuk transaksi itu **16.662 μs**. Pengiriman produksi dipindahkan ke relay proyek `https://api.windcrypto.com/rpc`, memakai alokasi `miner.wind` yang telah disediakan pemilik. Pembacaan dan rekonsiliasi historis tetap menggunakan `https://vexascan.com/rpc`. Pemantauan sekarang juga membaca CPU relay, dengan peringatan di bawah dua detik CPU tersedia dan perhatian segera di bawah 200.000 μs. Tidak ada pembelian resource tambahan dalam penanganan ini.

Wallet, jurnal, dan direktori riwayat produksi dipertahankan. Tidak ada penggantian kunci, perubahan pemilik, atau perubahan penerima reward.

## Hasil pengujian

| Pemeriksaan | Hasil |
| --- | --- |
| Solidity | 143 pengujian dalam suite lengkap; 15 pemeriksaan terarah termasuk empat kasus tambahan batas nilai dan pembersihan penanda |
| Tata letak penyimpanan | Enam perbandingan OpenZeppelin lulus, tanpa unsafe override |
| Rust | 51 pengujian library dan tiga updater lulus; dua fixture eksternal tidak termasuk perintah library tersebut |
| Integrasi bertanda tangan | Pemulihan transaksi, batas proof, reorganisasi klaim, dan klaim otomatis lulus pada jaringan lokal terpisah |
| Desktop Linux | Empat kelompok pengujian lulus |
| Paket aplikasi | Sepuluh pemeriksaan lulus |
| Pengamanan pelaksanaan | 41 pemeriksaan Python lulus |
| Pemindahan native | 41 transaksi nyata: implementasi awal, pemindahan, verifikasi, pembersihan, implementasi akhir, dan pembayaran reward lama |
| Beban penyimpanan native | 100, 1.000, 10.000, dan 20.000 proof; 20.000 klaim; seluruh pencatatan reward direkonsiliasi |
| Miner native | Dua miner, restart, klaim otomatis, respons pengiriman hilang, gangguan HTTP, latensi, dan kedua kontrol jeda |
| Operasi berkelanjutan | 30 menit, 106 proof diterima, 100 diklaim otomatis; enam sisanya dibayar saat penyelesaian pengujian; tanpa error tercatat |
| Reproduksi state mainnet | 6.892 proof, 3.057 epoch, 5.295 epoch publikasi beacon; interupsi dan pemulihan; seluruh 22 hak reward lama dibayar dalam reproduksi terpisah |

Pengujian beban menggunakan engine akuntansi deterministik untuk mengisolasi biaya penyimpanan. Sebanyak 1.402 transaksi memakai **1.617.591.919 gas** dalam **5.493,14 detik**. Hasil tersebut tidak mewakili kecepatan PoW produksi. Pengujian Keccak dan drand dilakukan terpisah dengan miner sebenarnya.

Pada pengukuran native yang sebanding, proof lanjutan menggunakan **186.482 → 134.661 gas**. Klaim setelah akun serta penghitung tersedia menggunakan **67.360 gas**, tanpa menambah baris status proof. CPU dan RSS miner diukur terpisah; dua sesi dengan gangguan jaringan mencatat RSS puncak sekitar **9,98 MB** dan **10,18 MB**. Jumlah RPC per proof pada sesi tersebut mencakup publikasi, klaim, pemulihan, dan gangguan yang disengaja.

Satu percobaan batch terlalu besar terkena batas CPU testnet dan diulang dengan batch terbatas. Satu pengujian lokal tidak melakukan hashing karena perlindungan beban host aktif, kemudian lulus pada host terisolasi yang tidak sibuk. Bukti kegagalan awal tetap disimpan. Tidak dilakukan stress test terhadap mainnet publik.

Receipt, hash transaksi, pengukuran RAM, dan cakupan pengujian tersedia di [testnet-verification.json](../release/testnet-verification.json). Reproduksi state mainnet tersedia di [migration-rehearsal.json](../release/migration-rehearsal.json); transaksi reproduksi tersebut bukan transaksi mainnet.

## Operasi produksi terverifikasi

Pemeriksaan dengan relay proyek mencatat **13 proof diterima** dan **11 klaim otomatis** dalam **254.44 detik**, tanpa error atau peringatan pada sesi tersebut. Layanan aktif dan pemantau berstatus **HEALTHY**. RAM tersedia saat sampel **14,194,178 byte**, dan CPU relay tersedia **16,435,712 μs**. Bukti transaksi dan pembacaan pada blok **11,673,588** tersedia pada catatan verifikasi mainnet.

Paket Linux [ZORU Miner 1.5.6](https://github.com/zoruco/zoru-miner/releases/tag/v1.5.6) sudah diterbitkan. Paket yang diunduh kembali cocok dengan checksum, tanda tangan Ed25519, binary produksi, dan manifest `61d3436b4e795989cf9112b37ac27ef0abc86e279c94e3061de7279ced76e730`. Sumbernya [d0d95e9](https://github.com/zoruco/zoru-miner/commit/d0d95e9684a5926097c29d73efdbc9e9aaa5141a), dengan catatan rilis bertanda tangan pada [fa97115](https://github.com/zoruco/zoru-miner/commit/fa9711591463be0c9b1c5a61235a71ca81da03f8). Konfigurasi relay dan pemantauan tersedia pada [75cca44](https://github.com/zoruco/zoru-pow/commit/75cca4409114d680224412298392b8033341074e).

Sesi pengukuran produksi sebelum perpindahan relay mencatat **21 proof**, **18 klaim otomatis**, **434,80 detik**, **4.009 panggilan RPC** atau **190,90 RPC per proof**, serta **153,63 detik CPU**. Angka itu mencakup pembacaan protokol, penyegelan, publikasi dan klaim. RSS produksi pada sampel terpisah adalah **14,68 MB**, dengan maksimum proses sekitar **139,41 MB** termasuk pembukaan wallet terenkripsi. Sesi awal yang mengalami antrean beacon mencatat **388,59 RPC per proof** selama 32.739,41 detik; perbedaan durasi dan kondisi jaringan membuat angka tersebut bukan perbandingan throughput yang terkontrol.

Dua RPC EVM memperlihatkan hash yang berbeda untuk nomor blok historis yang sama. Inventaris dan pemeriksaan receipt dalam laporan ini memakai view Vexascan yang dipatok pada blok; identitas native, bytecode, kepemilikan, akun dan penyimpanan kontrak diverifikasi terpisah. Perbedaan metadata tersebut dicatat sebagai batasan lintas penyedia, tanpa perubahan infrastruktur RPC di luar ZORU.

[Unduh bukti publik pemindahan dan pembersihan](https://github.com/zoruco/zoru-pow/releases/download/mainnet-2026-11-05/ZORU-mainnet-evidence-20261105.tar.gz); SHA-256 `7fbdd12b8e174e473917bbbee92832a75052eafc3a66640d863c98f8690a2c51`. Arsip berisi inventaris serta seluruh baris penyimpanan native yang relevan, tanpa kredensial atau jurnal penandatanganan.

## Kapasitas dan pemantauan

Pertumbuhan dasar setelah pembaruan adalah **346 byte per proof + 1.038 byte per epoch yang dibuka**, ditambah akun penerima, saldo token pertama, serta biaya kode dan administrasi yang terpisah. Klaim tidak menghilangkan kebutuhan menyimpan riwayat kepemilikan. Pertumbuhan RAM tetap positif.

Proyeksi 30 hari, 90 hari, satu, tiga, dan lima tahun untuk aktivitas rendah, perkiraan, dan tinggi tersedia di [model kapasitas](NATIVE_STORAGE.md#capacity-model). Dengan enam proof per menit dan satu epoch per menit, kebutuhan tambahan yang diproyeksikan sekitar **1,64 GB per tahun**, dengan jumlah penerima tetap. Angka itu bukan kuota yang telah dibeli.

Pemantauan memeriksa identitas jaringan, implementasi aktif, kepemilikan, issuer, backing reward, RAM native, dan kemajuan finalitas. Peringatan kapasitas ditetapkan pada kurang dari tujuh hari pertumbuhan terukur dan dinaikkan pada kurang dari satu hari. Pemantau tidak menandatangani atau mengirim transaksi.

Risiko operasional yang tetap berlaku mencakup kapasitas native bersama, ketersediaan drand dan RPC, konsensus VEX, keamanan host penandatangan, serta kewenangan owner yang sudah ada. Asal build wrapper native VEX belum dapat dibuktikan secara independen sampai revisi sumber persisnya; identitas WASM dan hasil pengukuran dicatat. Referensi primer beserta revisi yang diperiksa tersedia di [References](REFERENCES.md).

## Explorer dan pendaftaran token

Halaman publik menampilkan **ZoruLedger (Proxy)**, **ZoruDrandBeacon (Proxy)**, dan **ZoruKeccakEngine (Proxy)** berdasarkan implementasi aktif yang bytecode-nya cocok dengan sumber terverifikasi. Identitas sumber proxy tetap benar. Pemeriksaan nama mencakup API publik, tiga halaman pada browser, dan 14 pengujian tampilan yang lulus. Catatan explorer tersedia pada [b063e38](https://github.com/windvex/explorer-wind/commit/b063e38dba02a910de562c6e6cc027de20501013).

Pendaftaran token serta logo diajukan melalui [pengajuan yang sama, nomor 7](https://github.com/pixelgenius-id/vex-evm-tokenlist/pull/7). Nama, simbol, delapan desimal dan alamat token dibaca langsung dari mainnet. Logo PNG 256 × 256 berukuran 15.919 byte; data token memakai chain 6736 dan alamat huruf kecil. Pemeriksaan format dan logo lulus. Penggabungan belum selesai: validator belum menemukan pool SPARK Swap yang memenuhi syarat minimum 500 VEX. Umur token sebenarnya melewati tujuh hari pada 4 November 2026 pukul 15:13:14 UTC, tetapi API metadata validator belum memberikan blok deployment. Tidak ada dana likuiditas ditambahkan dalam pendaftaran ini.
