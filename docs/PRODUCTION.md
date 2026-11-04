# ZORU — Laporan produksi

Pembaruan ini mempertahankan alamat proxy mainnet, kepemilikan token, aturan penambangan, pembagian reward, dan batas suplai. Catatan pelaksanaan mainnet akan dilengkapi setelah seluruh pemeriksaan selesai. Saat laporan ini disiapkan, pemindahan data masih berlangsung dan penambangan masih dijeda.

## Alamat mainnet

Jaringan EVM menggunakan chain **6736**, dengan identitas native `f9f432b1851b5c179d2091a96f593aaed50ec7466b74f89301f957a83e56ce1f`.

| Kontrak | Alamat tetap |
| --- | --- |
| Token | `0xb972753d17C5131D127B6c22DDE79B91a3132D03` |
| Ledger | `0xFf53a9079C2853C39C5adBfca788cb0f12aCFF03` |
| Engine | `0x9eD52C07691Cd26758ed1Ebe05d86698a9e54e8C` |
| Beacon | `0x562249B5c3922fAfa31f350EfDb89E4F3F9a82fE` |
| Koordinator | `0xF5A9911A70aD0D9456C4228c08B74d161786F410` |

Implementasi akhir sudah dideploy pada alamat berikut. Aktivasi menunggu penyelesaian pemindahan dan pembersihan data.

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

## Keamanan dan pembayaran

Pemeriksaan mencakup Token, Ledger, Engine, Beacon, proxy, ProxyAdmin, koordinator upgrade, dan miner Rust. Temuan beserta hasil pemeriksaannya tersedia di [Protocol review](REVIEW.md).

Penyimpanan akhir mempunyai satu jalur pencatatan proof dan reward. Pembacaan sumber lama, jalur cadangan migrasi, dan fungsi pemindahan sementara tidak disertakan dalam implementasi akhir. Lokasi penyimpanan sebelumnya tetap dicadangkan agar tata letak proxy aman; nilainya dikosongkan setelah penggantinya terverifikasi. Delapan posisi penghitung dan penanda migrasi juga harus kosong sebelum aktivasi akhir.

Validasi resmi OpenZeppelin **1.47.0** meluluskan enam perbandingan tata letak tanpa pengecualian yang melewati pemeriksaan. Mapping proof awal tetap pada slot **13**, mapping epoch awal pada slot **12**, dan mapping baru ditambahkan pada slot **16** serta **21**. Hasil tersedia di [storage-validation.json](../release/storage-validation.json).

Verifikasi beacon tetap menggunakan tanda tangan drand yang diautentikasi. Pengujian mencakup jadwal round, domain tanda tangan, kunci publik tepercaya, titik kurva, subgroup, pairing precompile, vektor RFC 9380 independen, dan publikasi native dengan tanda tangan sebenarnya. Tidak ditemukan cara melewati verifikasi pada pengujian tersebut. Dependensi BLS upstream bersifat eksperimental dan belum memiliki audit kriptografi independen; pengujian ini tidak menggantikan audit tersebut.

## Miner

Pemulihan nonce menelusuri blok yang benar-benar mengonsumsi nonce, termasuk transaksi di luar jendela pencarian terbaru. Jurnal hanya diselesaikan setelah receipt transaksi pengganti terbukti kanonis. Respons pengiriman yang hilang tidak menyebabkan transaksi baru ditandatangani secara membabi buta.

Miner mempertahankan jurnal sebelum pengiriman, memverifikasi identitas jaringan pada RPC cadangan, menghormati kedua kontrol jeda kontrak, dan mengurangi pembacaan ulang proof yang sudah final. Hashing menggunakan kembali bagian challenge yang tetap. Pengukuran lokal tiga sampel, masing-masing 250.000 hash, menghasilkan median **620.667** menjadi **956.444 hash/detik** pada host pengujian; hasil ini bergantung pada beban host dan bukan jaminan throughput jaringan.

Saat pelaksanaan mainnet, beberapa pengiriman mendapat pengakuan eksekusi dari API native tetapi belum menghasilkan receipt EVM kanonis dalam batas waktu. Nonce native dan EVM tetap belum terpakai. Setelah pemeriksaan lintas RPC, byte transaksi bertanda tangan yang sama dikirim kembali dan terkonfirmasi tanpa tanda tangan atau nonce baru. Pemulihan berikutnya dibatasi pada dua percobaan dalam jendela pemeriksaan; transaksi tetap disimpan jika hasilnya belum dapat dibuktikan. Pengakuan relay diperlakukan terpisah dari konfirmasi blok dan finalitas native.

Log native juga mencatat `leeway_deadline_exception` saat kapasitas CPU relay `miner.wind` hampir penuh. Pemilik menambah alokasi CPU; pemeriksaan sesudahnya menunjukkan sekitar 38,4 detik tersedia, dan transaksi yang tertahan berhasil dikonfirmasi dengan byte yang sama. Kapasitas CPU relay perlu dipantau terpisah dari RAM `vex.evm`.

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

## Kapasitas dan pemantauan

Pertumbuhan dasar setelah pembaruan adalah **346 byte per proof + 1.038 byte per epoch yang dibuka**, ditambah akun penerima, saldo token pertama, serta biaya kode dan administrasi yang terpisah. Klaim tidak menghilangkan kebutuhan menyimpan riwayat kepemilikan. Pertumbuhan RAM tetap positif.

Proyeksi 30 hari, 90 hari, satu, tiga, dan lima tahun untuk aktivitas rendah, perkiraan, dan tinggi tersedia di [model kapasitas](NATIVE_STORAGE.md#capacity-model). Dengan enam proof per menit dan satu epoch per menit, kebutuhan tambahan yang diproyeksikan sekitar **1,64 GB per tahun**, dengan jumlah penerima tetap. Angka itu bukan kuota yang telah dibeli.

Pemantauan memeriksa identitas jaringan, implementasi aktif, kepemilikan, issuer, backing reward, RAM native, dan kemajuan finalitas. Peringatan kapasitas ditetapkan pada kurang dari tujuh hari pertumbuhan terukur dan dinaikkan pada kurang dari satu hari. Pemantau tidak menandatangani atau mengirim transaksi.

Risiko operasional yang tetap berlaku mencakup kapasitas native bersama, ketersediaan drand dan RPC, konsensus VEX, keamanan host penandatangan, serta kewenangan owner yang sudah ada. Asal build wrapper native VEX belum dapat dibuktikan secara independen sampai revisi sumber persisnya; identitas WASM dan hasil pengukuran dicatat. Referensi primer beserta revisi yang diperiksa tersedia di [References](REFERENCES.md).
